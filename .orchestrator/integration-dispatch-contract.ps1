# Shared by the existing landed producer and its canonical launch boundary.
# API fixtures replace only the remote API read; all Git probes remain native.
# Model identities are resolved from the AgentPools registry.  The pool-status
# payload is only an availability signal; it never defines the roster.
. (Join-Path $PSScriptRoot 'routing-data.ps1') -Library

function Get-IntegrationRoutingAuthority {
  param([switch]$ReadOnly)
  try { return Get-RoutingData -ReadOnly:$ReadOnly }
  catch { throw "INTEGRATION_ROUTING_DATA_REFUSED: $($_.Exception.Message)" }
}

function Get-IntegrationFamilyCurrent([object]$Data,[string]$Family) {
  $entry = $Data.registry.families.PSObject.Properties[$Family]
  if ($null -eq $entry -or $entry.Value.current -isnot [string]) {
    throw "INTEGRATION_ROUTING_FAMILY_MISSING: $Family"
  }
  return [string]$entry.Value.current
}
function Assert-IntegrationRequest($Request) {
  $keys = @('schemaVersion','requestIdentity','repository','pr','landedPr','landedHead','head','newBase','branch','worktree','label','sourceIdentity','sourceHead','runtimeRoot','historyPath')
  foreach($key in @('schemaVersion','requestIdentity','repository','landedHead','head','newBase','branch','worktree','label','sourceIdentity','sourceHead','runtimeRoot','historyPath')) { if ($Request.$key -isnot [string]) { throw "INTEGRATION_REQUEST_INVALID: $key type" } }
  $actual = @($Request.PSObject.Properties.Name)
  if ($actual.Count -ne $keys.Count -or @($keys | Where-Object { $_ -cnotin $actual }).Count -or
      $Request.schemaVersion -cne 'integration-dispatch-request/v1' -or
      -not (Test-DispatchJsonInteger $Request.pr 1) -or -not (Test-DispatchJsonInteger $Request.landedPr 1) -or
      $Request.repository -cnotmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' -or
      $Request.branch -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._/-]{0,255}$' -or
      $Request.label -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,199}$' -or
      $Request.requestIdentity -cnotmatch '^[a-f0-9]{64}$' -or
      $Request.sourceIdentity -cnotmatch '^(ABSENT_REVIEW_REQUIRED|[a-f0-9]{64})$' -or
      $Request.sourceHead -cnotmatch '^([a-f0-9]{40})?$' -or
      ($Request.sourceIdentity -ceq 'ABSENT_REVIEW_REQUIRED' -and $Request.sourceHead) -or
      ($Request.sourceIdentity -cmatch '^[a-f0-9]{64}$' -and $Request.sourceHead -cnotmatch '^[a-f0-9]{40}$')) { throw 'INTEGRATION_REQUEST_INVALID' }
  foreach ($key in @('head','newBase','landedHead')) { if ($Request.$key -cnotmatch '^[a-f0-9]{40}$') { throw "INTEGRATION_REQUEST_INVALID: $key" } }
  foreach ($key in @('worktree','runtimeRoot','historyPath')) { if (-not (Test-DispatchFullyQualifiedPath $Request.$key)) { throw "INTEGRATION_REQUEST_INVALID: $key" } }
  if (-not (Test-DispatchSamePath (Split-Path -Parent $Request.historyPath) $Request.runtimeRoot)) { throw 'INTEGRATION_REQUEST_INVALID: canonical history root' }
}

function Test-IntegrationAuthorRoute($Harness, $Model, $Effort, $Row, $Placement, [switch]$HistoricalRead) {
  $data = Get-IntegrationRoutingAuthority -ReadOnly
  $identity = Get-RoutingModelIdentity $data.registry $Model
  if ($null -eq $identity -or (-not $identity.current -and -not $HistoricalRead)) { return $false }
  $astra = $Harness -ceq 'codex' -and $identity.family -ceq 'astra' -and $identity.provider -ceq $Harness
  $fable = $Harness -ceq 'claude' -and $identity.family -ceq 'fable' -and $identity.provider -ceq $Harness
  return ($astra -or $fable) -and $Effort -ceq 'high' -and $Row -eq 7 -and $Placement -ceq 'override-Todd'
}

function Assert-IntegrationAuthor($Harness, $Model, $Effort, $Row, $Placement, [switch]$HistoricalRead) {
  if (-not (Test-IntegrationAuthorRoute $Harness $Model $Effort $Row $Placement -HistoricalRead:$HistoricalRead)) {
    throw 'INTEGRATION_AUTHOR_UNAVAILABLE: requires current astra/codex or fable/claude family at high/7/override-Todd'
  }
}

function Get-IntegrationPoolPreference([string]$AstraModel,[string]$PoolStatusFixturePath) {
  $astra='codex';$fable='claude'
  try {
    $body = if ($PoolStatusFixturePath) {
      Get-Content -LiteralPath $PoolStatusFixturePath -Raw
    } else {
      $url = if ($env:CODEX_POOL_STATUS_URL) { $env:CODEX_POOL_STATUS_URL } else { 'http://127.0.0.1:8318/api/status' }
      (Invoke-WebRequest -Uri $url -TimeoutSec 3 -NoProxy -ErrorAction Stop).Content
    }
    $status = $body | ConvertFrom-Json -DateKind String -ErrorAction Stop
    if ($null -eq $status -or $status.error -or $status.accounts -isnot [array]) { return $astra }
    foreach ($account in $status.accounts) {
      if ($account.provider -isnot [string] -or $account.disabled -isnot [bool]) { return $astra }
    }
    $accounts = @($status.accounts | Where-Object { $_.provider -ceq 'codex' -and $_.disabled -ceq $false })
    if ($accounts.Count -eq 0) { return $astra }
    $now = [datetimeoffset]::UtcNow
    foreach ($account in $accounts) {
      $routeProperty = $account.routingModels.PSObject.Properties[$AstraModel]
      $route = if ($routeProperty) { $routeProperty.Value } else { $null }
      $retry = [datetimeoffset]::MinValue
      if ($null -eq $route -or $route.status -cne 'blocked' -or
          $route.next_retry_after -isnot [string] -or
          $route.next_retry_after -cnotmatch '^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d+)?(?:Z|[+-]\d\d:\d\d)$' -or
          -not [datetimeoffset]::TryParse($route.next_retry_after, [ref]$retry) -or $retry -le $now) { return $astra }
    }
    return $fable
  } catch { return $astra }
}

function Get-LandedIntegrationAuthor([string]$PoolStatusFixturePath = '', [switch]$DefaultAstra) {
  $data = Get-IntegrationRoutingAuthority
  $astraModel = Get-IntegrationFamilyCurrent $data 'astra'
  $preference = if ($DefaultAstra) { 'codex' } else { Get-IntegrationPoolPreference $astraModel $PoolStatusFixturePath }
  # The status signal selects a preferred family, never bypasses the registry's
  # per-account admission. Protected authorship still closes the resolved route.
  $author = Resolve-RoutingSelection -Row 7 -Harness $preference
  $author.placement = 'override-Todd'
  Assert-IntegrationAuthor $author.harness $author.model $author.effort $author.row $author.placement
  return $author
}

function Invoke-IntegrationProbe([string]$Executable, [string[]]$Arguments) {
  $start = [Diagnostics.ProcessStartInfo]::new()
  $start.FileName = $Executable; $start.UseShellExecute = $false; $start.CreateNoWindow = $true
  $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
  $start.Environment['GIT_TERMINAL_PROMPT']='0'
  $start.Environment['GCM_INTERACTIVE']='Never'
  foreach ($argument in $Arguments) { [void]$start.ArgumentList.Add($argument) }
  $process = [Diagnostics.Process]::Start($start)
  try {
    $out = $process.StandardOutput.ReadToEndAsync(); $err = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit(30000)) {
      $process.Kill($true); $process.WaitForExit()
      throw "INTEGRATION_INPUT_UNKNOWN: $Executable probe deadline"
    }
    if ($process.ExitCode -ne 0) { throw "INTEGRATION_INPUT_UNKNOWN: $Executable exit=$($process.ExitCode) $($err.Result.Trim())" }
    return $out.Result.Trim()
  } finally { $process.Dispose() }
}

function Get-IntegrationAuthority([string]$Repository, [int]$Pr, [string]$FixturePath) {
  if ($FixturePath) {
    $payloads = @(Read-RebaseJson $FixturePath)
    $matches = @($payloads | Where-Object { $_.data.repository.pullRequest.number -eq $Pr })
    if ($matches.Count -ne 1) { throw 'INTEGRATION_INPUT_UNKNOWN: API fixture target count' }
    return $matches[0]
  }
  $owner, $name = $Repository.Split('/')
  $query = 'query($owner:String!,$name:String!,$pr:Int!){repository(owner:$owner,name:$name){nameWithOwner ref(qualifiedName:"refs/heads/main"){name target{oid}} pullRequest(number:$pr){number state headRefName headRefOid headRepository{nameWithOwner}}}}'
  $raw = Invoke-IntegrationProbe 'gh' @('api','graphql','-f',"query=$query",'-f',"owner=$owner",'-f',"name=$name",'-F',"pr=$Pr")
  $payload = $raw | ConvertFrom-Json -DateKind String -ErrorAction Stop
  if ($payload.errors) { throw 'INTEGRATION_INPUT_UNKNOWN: GraphQL errors' }
  return $payload
}

function Assert-IntegrationTarget([string]$Worktree, [string]$Branch, [string]$Head,
    [string]$NewBase, [string]$Repository, [int]$Pr, [string]$AuthorityFixturePath = '') {
  $observed = [ordered]@{worktree=$Worktree;branch=$Branch;requestedHead=$Head;requestedBase=$NewBase}
  try {
    $root = Get-DispatchCanonicalExistingPath $Worktree
    $top = Invoke-IntegrationProbe 'git' @('-C',$Worktree,'rev-parse','--show-toplevel')
    $observed.canonicalWorktree = Get-DispatchCanonicalExistingPath $top
    $observed.attachedRef = Invoke-IntegrationProbe 'git' @('-C',$Worktree,'symbolic-ref','-q','HEAD')
    $observed.localHead = Invoke-IntegrationProbe 'git' @('-C',$Worktree,'rev-parse','--verify','HEAD^{commit}')
    $observed.branchHead = Invoke-IntegrationProbe 'git' @('-C',$Worktree,'rev-parse','--verify',"refs/heads/${Branch}^{commit}")
    $observed.status = Invoke-IntegrationProbe 'git' @('--no-optional-locks','-C',$Worktree,'status','--porcelain=v1','--untracked-files=normal')
    $observed.currentBase = Invoke-IntegrationProbe 'git' @('-C',$Worktree,'rev-parse','--verify','refs/remotes/origin/main^{commit}')
    $remote = Invoke-IntegrationProbe 'git' @('-C',$Worktree,'ls-remote','--exit-code','--refs','origin',"refs/heads/$Branch",'refs/heads/main')
    $remoteRefs = @{}
    foreach ($line in @($remote -split "`r?`n")) {
      if ($line -cnotmatch '^([a-f0-9]{40})\s+(refs/heads/.+)$' -or $remoteRefs.ContainsKey($Matches[2])) { throw 'remote ref shape' }
      $remoteRefs[$Matches[2]] = $Matches[1]
    }
    $observed.remoteHead = $remoteRefs["refs/heads/$Branch"]
    $observed.remoteBase = $remoteRefs['refs/heads/main']
    $api = Get-IntegrationAuthority $Repository $Pr $AuthorityFixturePath
    $repo = $api.data.repository; $target = $repo.pullRequest
    $observed.prHead = $target.headRefOid; $observed.githubBase = $repo.ref.target.oid
    if ($root -eq $null -or -not (Test-DispatchSameCanonicalPath $root $observed.canonicalWorktree) -or
        -not (Test-DispatchSameCanonicalPath $root $Worktree) -or
        $observed.attachedRef -cne "refs/heads/$Branch" -or $observed.status -or
        $observed.localHead -cne $Head -or $observed.branchHead -cne $Head -or
        $observed.remoteHead -cne $Head -or $target.headRefOid -cne $Head -or
        $observed.currentBase -cne $NewBase -or $observed.remoteBase -cne $NewBase -or $observed.githubBase -cne $NewBase -or
        $repo.nameWithOwner -cne $Repository -or $target.headRepository.nameWithOwner -cne $Repository -or
        $repo.ref.name -cne 'main' -or $target.state -cne 'OPEN' -or $target.number -ne $Pr -or $target.headRefName -cne $Branch) {
      throw 'local/PR/remote/current-main identities differ'
    }
    $table = Invoke-IntegrationProbe 'git' @('-C',$Worktree,'worktree','list','--porcelain')
    $holders = @($table -split "`r?`n" | Where-Object { $_ -ceq "branch refs/heads/$Branch" })
    if ($holders.Count -ne 1) { throw 'ambiguous branch holders' }
    return [pscustomobject]$observed
  } catch {
    throw "INTEGRATION_TARGET_RECONCILIATION_REQUIRED: $($_.Exception.Message); observed=$($observed | ConvertTo-Json -Compress); action=author reconcile attached local, PR, remote branch and current main, then request fresh admission"
  }
}

function Get-IntegrationHelperArguments([int]$Pr, [string]$Head, [string]$NewBase,
    [string]$SourceIdentity, [string]$SourceHead, [string]$Lane, [string]$Worktree,
    [string]$RuntimeRoot, [string]$HistoryPath) {
  $arguments = @('-NoProfile','-NonInteractive','-File',(Join-Path $PSScriptRoot 'rebase-integration.ps1'),
    '-Pr',"$Pr",'-ReviewedHead',$Head,'-NewBase',$NewBase,'-SourcePassReceiptIdentity',$SourceIdentity,
    '-IntegrationLane',$Lane,'-Worktree',([IO.Path]::GetFullPath($Worktree)),
    '-RuntimeRoot',([IO.Path]::GetFullPath($RuntimeRoot)),'-HistoryPath',([IO.Path]::GetFullPath($HistoryPath)))
  if ($SourceHead) { $arguments += @('-SourcePassReviewedHead',$SourceHead) }
  return ,$arguments
}

function Get-IntegrationExitedState($Spec) {
  foreach ($pair in @(@($Spec.launcherPid,$Spec.launcherStartIdentity),@($Spec.childPid,$Spec.childStartIdentity))) {
    if (-not (Test-DispatchJsonInteger $pair[0] 1) -or -not (Test-DispatchUtcIdentity $pair[1])) { return 'unknown' }
    $process = @(Get-Process -Id $pair[0] -ErrorAction SilentlyContinue)
    if ($process.Count) {
      try {
        if ($process.Count -ne 1) { return 'unknown' }
        if ($process[0].StartTime.ToUniversalTime().Ticks -eq ([datetimeoffset]$pair[1]).ToUniversalTime().Ticks) { return 'live' }
        return 'reused'
      } catch { return 'unknown' }
    }
  }
  try {
    $seen = [Collections.Generic.HashSet[int]]::new()
    $queue = [Collections.Generic.Queue[int]]::new()
    $queue.Enqueue([int]$Spec.launcherPid); $queue.Enqueue([int]$Spec.childPid)
    while ($queue.Count) {
      $parent = $queue.Dequeue()
      if (-not $seen.Add($parent)) { continue }
      foreach ($child in @(Get-CimInstance Win32_Process -Filter "ParentProcessId = $parent" -ErrorAction Stop)) {
        if ($child.CreationDate -isnot [datetime]) { return 'unknown' }
        if ($child.CreationDate.ToUniversalTime() -ge ([datetimeoffset]$Spec.launcherStartIdentity).UtcDateTime) { return 'possible-descendant' }
        $queue.Enqueue([int]$child.ProcessId)
      }
    }
    return 'exited'
  } catch { return 'unknown' }
}

function Get-RetainedIntegrationStart([string]$AckPath, [string]$Identity, $Pr,
    [string]$Worktree, [string]$RuntimeRoot, [string]$HistoryPath) {
  $result = [ordered]@{pr=[int]$Pr.number;action='RETAINED_START_PENDING';requestIdentity=$Identity;requestedHead=[string]$Pr.headRefOid;actualHead=$null;reason='unknown'}
  $locks=[Collections.Generic.List[object]]::new()
  try {
    $locks.Add([IO.File]::Open($AckPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read))
    $ack = Read-RebaseJson $AckPath
    $keys = @('schemaVersion','requestIdentity','label','launchId','ownershipRecordPath','worktree','branch','head','harness','model','effort','row','placement','state','childPid','childStartIdentity')
    $routingKeys=@('policyGeneration','registryAuthorityDigest','family','slot','usedLastKnownGood')
    $hasRouting=@($routingKeys|Where-Object{$_ -cin @($ack.PSObject.Properties.Name)}).Count -gt 0
    if($hasRouting){
      $keys += $routingKeys
      if(-not(Test-DispatchJsonInteger $ack.policyGeneration 1)-or
        $ack.registryAuthorityDigest-isnot[string]-or$ack.registryAuthorityDigest-cnotmatch'^[a-zA-Z0-9._:-]{1,128}$'-or
        $ack.family-isnot[string]-or$ack.family-cnotmatch'^[a-z0-9][a-z0-9._-]{0,63}$'-or
        $ack.slot-isnot[string]-or$ack.slot-cnotmatch'^(explicit|(codex|claude)\.(primary|fallback))$'-or
        $ack.usedLastKnownGood-isnot[bool]){throw 'ack routing identity'}
    }
    if (@($ack.PSObject.Properties.Name).Count -ne $keys.Count -or @($keys | Where-Object { $_ -cnotin $ack.PSObject.Properties.Name }).Count -or
        $ack.schemaVersion -cne 'dispatch-start-ack/v1' -or $ack.requestIdentity -cne $Identity -or
        $ack.label -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,199}$' -or $ack.launchId -cnotmatch '^[a-f0-9-]{36}$' -or
        $ack.head -cnotmatch '^[a-f0-9]{40}$' -or $ack.branch -cne $Pr.headRefName -or
        -not (Test-DispatchSamePath $ack.worktree $Worktree) -or
        -not (Test-DispatchSamePath $ack.ownershipRecordPath (Join-Path $RuntimeRoot "dispatch-launch-$($ack.launchId).json")) -or
        $ack.state -cne 'started' -or -not (Test-DispatchJsonInteger $ack.childPid 1) -or -not (Test-DispatchUtcIdentity $ack.childStartIdentity)) { throw 'ack identity' }
    $result.actualHead = $ack.head
    $specPath = Join-Path $RuntimeRoot "watchdog-lane-$($ack.label).json"
    $locks.Add([IO.File]::Open($specPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read))
    $spec = Read-RebaseJson $specPath
    $freshRequest=$null
    if ($spec.schemaVersion -ceq 'watchdog-lane/v3') {
      $freshRequest=$spec.integrationRequest; Assert-IntegrationRequest $freshRequest
      Assert-IntegrationAuthor $spec.harness $spec.model $spec.effort $spec.row $spec.placement
      if ($freshRequest.requestIdentity -cne $Identity -or $freshRequest.label -cne $ack.label -or $freshRequest.head -cne $Pr.headRefOid -or $freshRequest.branch -cne $ack.branch -or -not (Test-DispatchSamePath $freshRequest.runtimeRoot $RuntimeRoot) -or -not (Test-DispatchSamePath $freshRequest.historyPath $HistoryPath) -or -not (Test-DispatchSamePath $freshRequest.worktree $Worktree)) { throw 'crossed bound request' }
      $spec.PSObject.Properties.Remove('integrationRequest');$spec.schemaVersion='watchdog-lane/v2'
    }
    $specKeys = @('schemaVersion','label','attemptId','relaunchCount','resumeOfLaunchId','harness','model','effort','row','placement','laneRole','originalPromptPath','partialReportPath','errorPath','worktree','branch','head','launchId','ownershipRecordPath','launcherPid','launcherStartIdentity','childPid','childStartIdentity','state','exitCode','updatedAt')
    if($hasRouting){
      $specKeys += $routingKeys
      foreach($key in $routingKeys){if($spec.$key-cne$ack.$key){throw 'crossed routing identity'}}
    }
    if (@($spec.PSObject.Properties.Name).Count -ne $specKeys.Count -or @($specKeys | Where-Object { $_ -cnotin $spec.PSObject.Properties.Name }).Count -or
        $spec.schemaVersion -cne 'watchdog-lane/v2' -or $spec.laneRole -cne 'implementation' -or
        $spec.attemptId -cne $ack.label -or $spec.relaunchCount -ne 0 -or $null -ne $spec.resumeOfLaunchId) { throw 'watchdog identity' }
    foreach ($key in @('label','launchId','head','branch','harness','model','effort','row','placement','childPid','childStartIdentity')) {
      if ([string]$spec.$key -cne [string]$ack.$key) { throw "crossed watchdog $key" }
    }
    foreach ($key in @('worktree','ownershipRecordPath')) { if (-not (Test-DispatchSamePath $spec.$key $ack.$key)) { throw "crossed watchdog $key" } }
    foreach ($pair in @(@('originalPromptPath',"$($ack.label).prompt.txt"),@('partialReportPath',"$($ack.label).jsonl"),@('errorPath',"$($ack.label).err.log"))) {
      if (-not (Test-DispatchSamePath $spec.($pair[0]) (Join-Path $RuntimeRoot $pair[1]))) { throw 'crossed retained path' }
    }
    foreach($path in @($HistoryPath,$spec.originalPromptPath,$spec.partialReportPath,$spec.errorPath)) { $locks.Add([IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)) }
    $history = Read-ExactHeadReviewHistory -Path $HistoryPath
    if (-not $history.complete) { throw 'routing history unknown' }
    $routes = @($history.rows | Where-Object { $_.value.dispatchRoutingSchema -cin @('watchdog-dispatch-routing/v1','watchdog-dispatch-routing/v2','watchdog-dispatch-routing/v3') -and $_.value.label -ceq $ack.label })
    if ($routes.Count -ne 1) { throw 'routing history ambiguous' }
    $route = $routes[0].value
    $routeKeys = @(Get-DispatchRoutingLedgerKeys $route.dispatchRoutingSchema $route)
    if (-not (Test-DispatchRoutingLedgerEvidence $route) -or @($route.PSObject.Properties.Name).Count -ne $routeKeys.Count -or @($routeKeys | Where-Object { $_ -cnotin $route.PSObject.Properties.Name }).Count -or
        $route.kind -cne 'dispatch' -or $route.laneRole -cne 'implementation' -or $route.attemptId -cne $spec.attemptId -or
        $route.transcript -cne "$($ack.label).jsonl" -or $route.lane -cne (Split-Path -Leaf $Worktree) -or
        -not (Test-DispatchSamePath $route.worktree $Worktree)) { throw 'routing identity' }
    foreach ($key in @('head','branch','harness','model','effort','row','placement')) { if ([string]$route.$key -cne [string]$ack.$key) { throw "crossed routing $key" } }
    if (-not (Test-DispatchUtcIdentity $route.ts) -or -not (Test-DispatchUtcIdentity $spec.updatedAt) -or
        [datetimeoffset]$route.ts -lt [datetimeoffset]$spec.launcherStartIdentity -or
        [datetimeoffset]$route.ts -gt [datetimeoffset]$ack.childStartIdentity -or
        [datetimeoffset]$spec.updatedAt -lt [datetimeoffset]$ack.childStartIdentity -or [datetimeoffset]$spec.updatedAt -gt [datetimeoffset]::UtcNow) { throw 'retained time ordering' }
    if (Test-Path -LiteralPath $ack.ownershipRecordPath) {
      $owner=Get-ValidatedDispatchOwnershipRecord $ack.ownershipRecordPath ([IO.Path]::GetFullPath($RuntimeRoot)) ([IO.Path]::GetTempPath())
      if ($null -eq $owner -or $owner.launchId -cne $ack.launchId -or $owner.launcherPid -ne $spec.launcherPid -or $owner.launcherStartIdentity -cne $spec.launcherStartIdentity -or $owner.childPid -ne $ack.childPid -or $owner.childStartIdentity -cne $ack.childStartIdentity) { throw 'crossed retained ownership record' }
    }
    $result.reason = Get-IntegrationExitedState $spec
    if ($result.reason -cne 'exited') { return $result }
    if ($spec.state -cne 'exited' -or -not (Test-DispatchJsonInteger $spec.exitCode 0) -or $spec.exitCode -ne 0) { throw 'native exit unknown' }
    $prompt = [IO.File]::ReadAllText($spec.originalPromptPath)
    if ($freshRequest) {
      $requestPath=Join-Path $RuntimeRoot "integration-request-$($ack.label).json"
      $locks.Add([IO.File]::Open($requestPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read))
      if ((Get-RebaseRecordIdentity (Read-RebaseJson $requestPath)) -cne (Get-RebaseRecordIdentity $freshRequest)) { throw 'retained request bytes differ' }
    } elseif (-not $prompt.Contains("ReviewedHead $($Pr.headRefOid)") -or -not $prompt.Contains("PR #$($Pr.number)")) { throw 'requested prompt identity' }
    if ($ack.head -ceq $Pr.headRefOid) { $result.action='RETAINED_STARTED';$result.reason='exact original start retained; completion requires its original result evidence';return $result }
    Assert-IntegrationParameterStopTranscript ([IO.File]::ReadAllText($spec.partialReportPath))
    $native = Get-DispatchGitIdentity $Worktree
    if ($native.status -cne 'ok' -or $native.branch -cne $ack.branch -or $native.head -cne $ack.head -or
        (Invoke-IntegrationProbe 'git' @('--no-optional-locks','-C',$Worktree,'status','--porcelain=v1'))) { throw 'current Git moved or observation unknown' }
    # No branch or HEAD movement during/after this native launch. Neither a
    # missing result envelope nor a parameter error alone establishes this.
    foreach($ref in @('HEAD',"refs/heads/$($ack.branch)")) {
      $log=Invoke-IntegrationProbe 'git' @('-C',$Worktree,'reflog','show','--date=raw','--format=%H%x09%gD',$ref)
      if (-not $log) { throw 'native reflog missing' }
      foreach($line in @($log -split "`r?`n")) {
        if ($line -cnotmatch '^[a-f0-9]{40}\t.+@\{([0-9]+) [+-][0-9]{4}\}$') { throw 'native reflog unknown' }
        if ([long]$Matches[1] -ge ([datetimeoffset]$spec.launcherStartIdentity).ToUnixTimeSeconds()) { throw 'native Git movement since start' }
      }
    }
    $record = [ordered]@{schemaVersion='integration-start-observation/v1';requestIdentity=$Identity;launchId=$ack.launchId;requestedHead=[string]$Pr.headRefOid;actualStartHead=$ack.head;observedHead=$native.head;harness=$ack.harness;model=$ack.model;effort=$ack.effort;row=$ack.row;placement=$ack.placement;status='EXITED_START_MISMATCH';nativeExitCode=[long]$spec.exitCode;integrationResult=$false;observedAt=[DateTime]::UtcNow.ToString('o');ackHash=Get-RebaseHash ([IO.File]::ReadAllBytes($AckPath));watchdogHash=Get-RebaseHash ([IO.File]::ReadAllBytes($specPath));transcriptHash=Get-RebaseHash ([IO.File]::ReadAllBytes($spec.partialReportPath));routeIdentity=Get-RebaseRecordIdentity $route;promptHash=Get-RebaseHash ([IO.File]::ReadAllBytes($spec.originalPromptPath));requestHash=$(if($freshRequest){Get-RebaseRecordIdentity $freshRequest}else{$null})}
    $observationPath=Join-Path $RuntimeRoot "integration-start-observation-$Identity.json"
    if (Test-Path -LiteralPath $observationPath) {
      $existing=Read-RebaseJson $observationPath
      Assert-RebaseKeys $existing @($record.Keys)
      if (-not (Test-DispatchUtcIdentity $existing.observedAt) -or [datetimeoffset]$existing.observedAt -gt [datetimeoffset]::UtcNow -or [datetimeoffset]$existing.observedAt -lt [datetimeoffset]$spec.updatedAt) { throw 'retained observation time' }
      $record.observedAt=$existing.observedAt
      if ((Get-RebaseRecordIdentity $existing) -cne (Get-RebaseRecordIdentity $record)) { throw 'retained observation mismatch' }
    } else { [void](Write-RebaseRecord $observationPath $record) }
    $result.action='EXITED_START_MISMATCH';$result.reason='author reconciliation and fresh admission required; no integration result';$result.observationPath=$observationPath
    return $result
  } catch { $result.reason=$_.Exception.Message;return $result } finally { foreach($handle in $locks) { $handle.Dispose() } }
}

# Inspect native command structure as data. Never evaluate transcript text.
function Assert-IntegrationParameterStopTranscript([string]$Raw) {
  if (-not $Raw.EndsWith("`n")) { throw 'native transcript incomplete' }
  $events=@($Raw -split "`r?`n" | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json -DateKind String -ErrorAction Stop })
  if ($events.Count -eq 0 -or $events[-1].type -cne 'turn.completed') { throw 'native transcript incomplete' }
  $stops=0;$commands=0;$started=@{};$completed=@{}
  if (@($events | Where-Object { $_.type -ceq 'turn.completed' }).Count -ne 1) { throw 'ambiguous native terminal' }
  foreach($event in $events) {
    if ($event.type -cnotin @('thread.started','turn.started','item.started','item.completed','turn.completed')) { throw 'unknown native event' }
    if ($event.type -cnotin @('item.started','item.completed')) { continue }
    if ($event.item.type -cnotin @('reasoning','agent_message','command_execution')) { throw 'native mutation or unknown tool' }
    if ($event.item.type -cne 'command_execution') { continue }
    if ($event.item.id -isnot [string] -or -not $event.item.id) { throw 'native command identity missing' }
    if ($event.type -ceq 'item.started') { if ($started.ContainsKey($event.item.id)) { throw 'duplicate native start' };$started[$event.item.id]=$event.item.command;continue }
    if ($completed.ContainsKey($event.item.id)) { throw 'duplicate native completion' };$completed[$event.item.id]=$event.item.command
    $commands++
    $item=$event.item
    if ($item.command -cnotmatch ' -Command "(.*)"$') { throw 'unrecognized native command wrapper' }
    $body=$Matches[1].Replace('\\','\')
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseInput($body,[ref]$tokens,[ref]$errors)
    $calls=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.CommandAst]},$true))
    if ($errors.Count -or $calls.Count -ne 1 -or $ast.EndBlock.Statements.Count -ne 1 -or
        $ast.EndBlock.Statements[0] -isnot [Management.Automation.Language.PipelineAst] -or $ast.EndBlock.Statements[0].PipelineElements.Count -ne 1 -or $calls[0].Redirections.Count) { throw 'native command has additional effects' }
    foreach($element in $calls[0].CommandElements) {
      if ($element -is [Management.Automation.Language.CommandParameterAst] -and $null -ne $element.Argument -and $element.Argument -isnot [Management.Automation.Language.StringConstantExpressionAst] -and $element.Argument -isnot [Management.Automation.Language.ConstantExpressionAst]) { throw 'native parameter expression unknown' }
      if ($element -isnot [Management.Automation.Language.StringConstantExpressionAst] -and $element -isnot [Management.Automation.Language.ConstantExpressionAst] -and $element -isnot [Management.Automation.Language.CommandParameterAst]) { throw 'native command expression unknown' }
    }
    $name=$calls[0].GetCommandName()
    if ($name -ieq 'Get-Content') { continue }
    if ((Split-Path -Leaf $name) -cne 'rebase-integration.ps1') { throw 'native command outside parameter-stop surface' }
    $params=@($calls[0].CommandElements | Where-Object { $_ -is [Management.Automation.Language.CommandParameterAst] } | ForEach-Object { $_.ParameterName })
    if ($params.Count -eq 1 -and $params[0] -ceq '?' -and $item.exit_code -eq 0) { continue }
    if ($item.exit_code -ne 1 -or $item.aggregated_output -notmatch "A parameter cannot be found that matches parameter name|missing mandatory parameters" -or
        $item.aggregated_output -match 'rebase-integration-result/v1') { throw 'native helper did not stop at parameter binding' }
    $stops++
  }
  foreach($id in $started.Keys) { if (-not $completed.ContainsKey($id) -or $completed[$id] -cne $started[$id]) { throw 'native command unfinished or crossed' } }
  if ($commands -eq 0 -or $stops -eq 0) { throw 'parameter stop not established' }
}

# Owed-v1/ack-v2 never recorded a model. An absent join stays null; completion
# authority remains the existing acknowledgement reader, independent of this
# observational attribution. A no-owner mechanical claim is not a new author.
function Get-IntegrationExecutionAttribution($Obligation,[string]$RuntimeRoot,[string]$HistoryPath) {
  $identity=Get-RebaseObligationIdentity $Obligation
  $launch=$null
  $completion=Read-RebaseCompletion $Obligation $RuntimeRoot -Replay
  if ($completion) { $launch=$completion.executionOwner.launchId }
  else {
    $accepts=@(Get-ChildItem -LiteralPath $RuntimeRoot -Filter "integration-owed-accept-$identity-*.json" -File)
    if ($accepts.Count -ne 1) { return $null }
    $accept=Read-RebaseJson $accepts[0].FullName
    Assert-RebaseKeys $accept @('schemaVersion','obligationIdentity','ownerLaunchId','ownerRecordPath','branch','worktree','ownerPid','ownerStartIdentity','acceptedAt')
    if ($accept.schemaVersion -cne 'landed-integration-owed-accept/v1' -or -not (Test-DispatchJsonInteger $accept.ownerPid 1) -or -not (Test-DispatchUtcIdentity $accept.ownerStartIdentity) -or -not (Test-DispatchUtcIdentity $accept.acceptedAt)) { return $null }
    if ($accept.obligationIdentity -cne $identity -or $accept.branch -cne $Obligation.branch -or -not (Test-DispatchSamePath $accept.worktree $Obligation.worktree)) { return $null }
    $launch=$accept.ownerLaunchId
  }
  $specs=@(Get-ChildItem -LiteralPath $RuntimeRoot -Filter 'watchdog-lane-*.json' -File | ForEach-Object { Read-RebaseJson $_.FullName } | Where-Object { $_.launchId -ceq $launch })
  if ($specs.Count -ne 1) { return $null }
  $spec=$specs[0]
  if ($spec.branch -cne $Obligation.branch -or -not (Test-DispatchSamePath $spec.worktree $Obligation.worktree) -or $spec.laneRole -cne 'implementation') { return $null }
  if ($completion) {
    foreach($key in @('launcherPid','launcherStartIdentity','childPid','childStartIdentity','head')) { if ([string]$spec.$key -cne [string]$completion.executionOwner.$key) { return $null } }
  } elseif ($spec.launcherPid -ne $accept.ownerPid -or $spec.launcherStartIdentity -cne $accept.ownerStartIdentity -or -not (Test-DispatchSamePath $spec.ownershipRecordPath $accept.ownerRecordPath)) { return $null }
  $history=Read-ExactHeadReviewHistory -Path $HistoryPath
  if (-not $history.complete) { return $null }
  $routes=@($history.rows | ForEach-Object { $_.value } | Where-Object { $_.dispatchRoutingSchema -cin @('watchdog-dispatch-routing/v1','watchdog-dispatch-routing/v2','watchdog-dispatch-routing/v3') -and $_.label -ceq $spec.label })
  if ($routes.Count -ne 1) { return $null }
  $route=$routes[0]
  Assert-RebaseKeys $route @(Get-DispatchRoutingLedgerKeys $route.dispatchRoutingSchema $route)
  if (-not (Test-DispatchRoutingLedgerEvidence $route)) { return $null }
  foreach($key in @('head','branch','harness','model','effort','row','placement','attemptId','laneRole')) { if ([string]$route.$key -cne [string]$spec.$key) { return $null } }
  if ($route.kind -cne 'dispatch' -or $route.transcript -cne "$($spec.label).jsonl" -or -not (Test-DispatchSamePath $route.worktree $Obligation.worktree) -or
      -not (Test-DispatchUtcIdentity $route.ts) -or [datetimeoffset]$route.ts -lt [datetimeoffset]$spec.launcherStartIdentity -or [datetimeoffset]$route.ts -gt [datetimeoffset]$spec.childStartIdentity) { return $null }
  return [ordered]@{launchId=$launch;harness=$spec.harness;model=$spec.model;effort=$spec.effort;row=[long]$spec.row;placement=$spec.placement;routeIdentity=Get-RebaseRecordIdentity $route}
}
