param([switch]$ProductCensusOnly)
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "dispatch-ownership.ps1")
. (Join-Path $PSScriptRoot 'product-census-test-support.ps1')
Test-ProductCensusProjection
Test-ProductCensusProofMatrix
Test-ProductCensusNativeBoundaries
if ($ProductCensusOnly) { return }

$root = Join-Path ([IO.Path]::GetTempPath()) ("dispatch-ownership-test-" + [guid]::NewGuid())
$runtime = Join-Path $root "runtime"
$providerTemp = Join-Path $root "provider-temp"
$container = Join-Path $root "container"
New-Item -ItemType Directory -Path $runtime, $providerTemp, $container | Out-Null

function Assert-True([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}

function Invoke-TestGit([string]$Worktree, [string[]]$Arguments) {
  $priorErrorAction = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    $output = @(& git -C $Worktree @Arguments 2>&1)
    $exitCode = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $priorErrorAction
  }
  if ($exitCode -ne 0) {
    throw "fixture git command failed: git -C $Worktree $($Arguments -join ' ')`n$($output -join "`n")"
  }
  return ($output -join "`n").Trim()
}

function New-ControlRuntime([string]$Name) {
  $path = Join-Path $root $Name
  New-Item -ItemType Directory -Path $path | Out-Null
  return $path
}

function New-ReducerOwnershipRecord(
  [string]$ControlRuntime,
  [string]$Worktree,
  [string]$LaneRole = "implementation",
  [string]$IdentityMode = "branch",
  [AllowNull()][string]$RecordedBranch,
  [AllowNull()][string]$RecordedHead,
  [int]$ChildPid = $PID,
  [string]$ChildStartIdentity,
  [int]$SchemaVersion = 4,
  [string]$LaunchId = ([guid]::NewGuid().ToString())
) {
  $lane = Split-Path -Leaf ([IO.Path]::GetFullPath($Worktree).TrimEnd("\", "/"))
  if ($SchemaVersion -in @(3, 4)) {
    if (-not $PSBoundParameters.ContainsKey("RecordedBranch")) {
      $RecordedBranch = Invoke-TestGit $Worktree @("branch", "--show-current")
    }
    if (-not $PSBoundParameters.ContainsKey("RecordedHead")) {
      $RecordedHead = (Invoke-TestGit $Worktree @("rev-parse", "HEAD")).ToLowerInvariant()
    }
  }
  if (-not $PSBoundParameters.ContainsKey("ChildStartIdentity")) {
    $ChildStartIdentity = Get-DispatchProcessStartIdentity $ChildPid
  }
  $recordPath = Join-Path $ControlRuntime "dispatch-launch-$LaunchId.json"
  $values = [ordered]@{
    schemaVersion = $SchemaVersion
    launchId = $LaunchId
    laneRole = $LaneRole
    promptPath = [IO.Path]::GetFullPath((Join-Path $ControlRuntime "dispatch-heavy-verifier-$LaunchId.prompt.txt"))
    reviewIsolationRoot = $(if ($LaneRole -in @("review", "planning")) {
      [IO.Path]::GetFullPath((Join-Path $providerTemp "chase-sets-$LaneRole-$LaunchId"))
    } else { $null })
    launcherPid = 999999
    launcherStartIdentity = "2000-01-01T00:00:00.0000000Z"
    recordedAt = [DateTime]::UtcNow.ToString("o")
    state = "started"
    childPid = $ChildPid
    childStartIdentity = $ChildStartIdentity
  }
  if ($SchemaVersion -in @(3, 4)) {
    $values.worktree = [IO.Path]::GetFullPath($Worktree).TrimEnd("\", "/")
    $values.lane = $lane
    $values.identityMode = $IdentityMode
    $values.branch = $(if ($IdentityMode -eq "immutable-head") { $null } else { $RecordedBranch })
    $values.head = $RecordedHead
  }
  if ($SchemaVersion -eq 4) {
    $values.label = "test-$LaunchId"
    $values.transcriptPath = [IO.Path]::GetFullPath(
      (Join-Path $ControlRuntime "$($values.label).jsonl")
    )
    [IO.File]::WriteAllText(
      $values.transcriptPath,
      "{`"type`":`"item.completed`"}`n",
      [Text.UTF8Encoding]::new($false)
    )
  }
  $record = [pscustomobject]$values
  Write-DispatchOwnershipRecord $recordPath $record -CreateNew
  return [pscustomobject]@{ path = $recordPath; record = $record }
}

function Add-ControlWorktree(
  [string]$Main,
  [string]$Lane,
  [string]$Branch,
  [switch]$Detached
) {
  $path = Join-Path $container $Lane
  if ($Detached) {
    Invoke-TestGit $Main @("worktree", "add", "--detach", $path, "HEAD") | Out-Null
  } else {
    Invoke-TestGit $Main @("worktree", "add", "-b", $Branch, $path, "HEAD") | Out-Null
  }
  return $path
}

function New-TestOwnershipRecord(
  [string]$Lane = "lane-01",
  [string]$LaneRole = "implementation",
  [string]$IdentityMode = "branch",
  [AllowNull()][string]$Branch = "codex/issue-6073",
  [int]$SchemaVersion = 4
) {
  $launchId = [guid]::NewGuid().ToString()
  $promptPath = Join-Path $runtime "dispatch-heavy-verifier-$launchId.prompt.txt"
  $recordPath = Join-Path $runtime "dispatch-launch-$launchId.json"
  $isolationRoot = if ($LaneRole -in @("review", "planning")) {
    Join-Path $providerTemp "chase-sets-$LaneRole-$launchId"
  } else {
    $null
  }
  $values = [ordered]@{
    schemaVersion = $SchemaVersion
    launchId = $launchId
    laneRole = $LaneRole
    promptPath = [IO.Path]::GetFullPath($promptPath)
    reviewIsolationRoot = $(if ($isolationRoot) { [IO.Path]::GetFullPath($isolationRoot) } else { $null })
    launcherPid = 999999
    launcherStartIdentity = "2000-01-01T00:00:00.0000000Z"
    recordedAt = [DateTime]::UtcNow.ToString("o")
    state = "started"
    childPid = 999998
    childStartIdentity = "2000-01-01T00:00:00.0000000Z"
  }
  if ($SchemaVersion -in @(3, 4)) {
    $values.worktree = [IO.Path]::GetFullPath((Join-Path $container $Lane)).TrimEnd("\", "/")
    $values.lane = $Lane
    $values.identityMode = $IdentityMode
    $values.branch = $(if ($IdentityMode -eq "immutable-head") { $null } else { $Branch })
    $values.head = "a" * 40
  }
  if ($SchemaVersion -eq 4) {
    $values.label = "test-$launchId"
    $values.transcriptPath = [IO.Path]::GetFullPath(
      (Join-Path $runtime "$($values.label).jsonl")
    )
    [IO.File]::WriteAllText(
      $values.transcriptPath,
      "{`"type`":`"item.completed`"}`n",
      [Text.UTF8Encoding]::new($false)
    )
  }
  $record = [pscustomobject]$values
  Write-DispatchOwnershipRecord $recordPath $record -CreateNew
  [pscustomobject]@{ path = $recordPath; record = $record }
}

try {
  $currentStart = Get-DispatchProcessStartIdentity $PID
  $identityJson = [ordered]@{ childStartIdentity = $currentStart } |
    ConvertTo-Json -Compress
  $roundTripped = ConvertFrom-DispatchOwnershipJson $identityJson
  Assert-True ($roundTripped.childStartIdentity -is [string] -and
    [string]::Equals(
      [string]$roundTripped.childStartIdentity,
      $currentStart,
      [StringComparison]::Ordinal
    )) "process-start identity round-trips as an exact string"
  if ($PSVersionTable.PSEdition -ceq "Core") {
    $fallbackFailedClosed = $false
    try {
      ConvertFrom-DispatchOwnershipJson $identityJson -DateKindSupported $false | Out-Null
    } catch {
      $fallbackFailedClosed = $true
    }
    Assert-True $fallbackFailedClosed "PowerShell Core without DateKind fails closed instead of coercing an identity"
  }

  $branch = New-TestOwnershipRecord
  $validatedBranch = Get-ValidatedDispatchOwnershipRecord $branch.path $runtime $providerTemp
  Assert-True ($null -ne $validatedBranch -and
    $validatedBranch.identityMode -ceq "branch" -and
    $validatedBranch.branch -ceq "codex/issue-6073") "schema-v3 branch ownership validates exact Git identity fields"

  $detached = New-TestOwnershipRecord -Lane "20260724-6069-review" -LaneRole "review" `
    -IdentityMode "immutable-head" -Branch $null
  $validatedDetached = Get-ValidatedDispatchOwnershipRecord $detached.path $runtime $providerTemp
  Assert-True ($null -ne $validatedDetached -and
    $validatedDetached.identityMode -ceq "immutable-head" -and
    $null -eq $validatedDetached.branch) "schema-v3 detached review validates an immutable HEAD without inventing a branch"

  $malformed = New-TestOwnershipRecord -Lane "lane-06;C"
  Assert-True ($null -eq (Get-ValidatedDispatchOwnershipRecord $malformed.path $runtime $providerTemp)) "malformed lane identity fails closed"

  $wrongHead = $branch.record.PSObject.Copy()
  $wrongHead.head = "b" * 40
  Assert-True (-not (Test-DispatchOwnershipRecordExact $branch.record $wrongHead)) "exact ownership comparison includes the dispatch HEAD"

  $legacy = New-TestOwnershipRecord -SchemaVersion 2
  Assert-True ($null -ne (Get-ValidatedDispatchOwnershipRecord $legacy.path $runtime $providerTemp)) "schema-v2 remains readable for safe stale-resource cleanup"

  if ($PSVersionTable.PSEdition -ceq "Core") {
    $fallbackRecord = New-TestOwnershipRecord
    $fallbackRecord.record.launcherPid = $PID
    $fallbackRecord.record.launcherStartIdentity = $currentStart
    $fallbackRecord.record.childPid = $PID
    $fallbackRecord.record.childStartIdentity = $currentStart
    Write-DispatchOwnershipRecord $fallbackRecord.path $fallbackRecord.record
    $parsedLiveRecord = ConvertFrom-DispatchOwnershipJson (
      Get-Content -LiteralPath $fallbackRecord.path -Raw
    )
    Assert-True ($parsedLiveRecord.childStartIdentity -is [string] -and
      [string]::Equals(
        [string]$parsedLiveRecord.childStartIdentity,
        $currentStart,
        [StringComparison]::Ordinal
      )) "an on-disk live record preserves the exact process-start identity string"
    Assert-True ($null -eq (Get-ValidatedDispatchOwnershipRecord $fallbackRecord.path $runtime $providerTemp `
      -DateKindSupported $false)) "forced PowerShell Core fallback rejects the record before identity coercion"
    $fallbackScavenge = Invoke-DispatchOwnershipScavenge $runtime $providerTemp `
      -DateKindSupported $false
    Assert-True ($fallbackScavenge.removed -eq 0 -and
      $fallbackScavenge.preserved -eq $fallbackScavenge.scanned -and
      (Test-Path -LiteralPath $fallbackRecord.path)) "forced Core fallback preserves every record and removes no live resource (scanned=$($fallbackScavenge.scanned) preserved=$($fallbackScavenge.preserved) rejected=$($fallbackScavenge.rejected) removed=$($fallbackScavenge.removed))"
  }

  $unknown = New-TestOwnershipRecord
  $unknown.record.schemaVersion = 5
  Write-DispatchOwnershipRecord $unknown.path $unknown.record
  Assert-True ($null -eq (Get-ValidatedDispatchOwnershipRecord $unknown.path $runtime $providerTemp)) "unknown ownership schema fails closed"

  # Real Git controls reproduce the live branch-mode lifecycle. Each runtime
  # contains exactly one owner unless the named guard is duplicate ownership.
  $identityMain = Join-Path $container "main"
  New-Item -ItemType Directory -Path $identityMain | Out-Null
  Invoke-TestGit $identityMain @("init", "--initial-branch=main") | Out-Null
  Invoke-TestGit $identityMain @("config", "user.name", "Dispatch Ownership Test") | Out-Null
  Invoke-TestGit $identityMain @("config", "user.email", "dispatch-ownership@example.invalid") | Out-Null
  [IO.File]::WriteAllText(
    (Join-Path $identityMain "seed.txt"),
    "ownership fixture",
    [Text.UTF8Encoding]::new($false)
  )
  Invoke-TestGit $identityMain @("add", "seed.txt") | Out-Null
  Invoke-TestGit $identityMain @("commit", "-m", "fixture seed") | Out-Null

  $advancedWorktree = Add-ControlWorktree $identityMain "lane-01" "agent/issue-6263-registration-atomicity"
  $advancedRuntime = New-ControlRuntime "branch-advanced-runtime"
  $advancedRecord = New-ReducerOwnershipRecord $advancedRuntime $advancedWorktree
  Invoke-TestGit $advancedWorktree @("switch", "-c", "opus/issue-6225-consent-bundles") | Out-Null
  Invoke-TestGit $advancedWorktree @("commit", "--allow-empty", "-m", "advance branch and head") | Out-Null
  $advancedHead = (Invoke-TestGit $advancedWorktree @("rev-parse", "HEAD")).ToLowerInvariant()
  $observedOwnerPids = [Collections.Generic.List[int]]::new()
  $advancedOwners = Get-LiveDispatchOwnership $advancedRuntime $providerTemp $container `
    -ProcessStateResolver {
      param($ProcessId, $StartIdentity)
      $observedOwnerPids.Add([int]$ProcessId)
      if ([int]$ProcessId -eq $PID) { "live" } else { "dead" }
    }
  Assert-True ($advancedOwners.health.status -eq "ok" -and
    @($advancedOwners.activeLanes).Count -eq 1) "branch advancement retains the exact live owner"
  Assert-True ($observedOwnerPids.Count -eq 1 -and
    $observedOwnerPids[0] -eq $PID -and
    $observedOwnerPids -notcontains $advancedRecord.record.launcherPid) "a dead launcher with its exact live started child remains live"
  Assert-True ((Test-DispatchSameCanonicalPath $advancedOwners.activeLanes[0].worktree $advancedWorktree) -and
    $advancedOwners.activeLanes[0].branch -ceq "opus/issue-6225-consent-bundles" -and
    $advancedOwners.activeLanes[0].head -ceq $advancedHead -and
    $advancedOwners.activeLanes[0].head -cne $advancedRecord.record.head) "advanced branch owner publishes live Git branch and head"

  $createdWorktree = Add-ControlWorktree $identityMain "lane-02" "main-at-launch"
  $createdRuntime = New-ControlRuntime "branch-created-runtime"
  New-ReducerOwnershipRecord $createdRuntime $createdWorktree | Out-Null
  Invoke-TestGit $createdWorktree @("switch", "-c", "codex/issue-6292-created-after-launch") | Out-Null
  $createdOwners = Get-LiveDispatchOwnership $createdRuntime $providerTemp $container
  Assert-True ($createdOwners.health.status -eq "ok" -and
    $createdOwners.activeLanes[0].branch -ceq "codex/issue-6292-created-after-launch") "branch creation after launch retains the exact live owner"

  $detachedWorktree = Add-ControlWorktree $identityMain "lane-03" "codex/issue-6292-rebase"
  $detachedRuntime = New-ControlRuntime "branch-detached-runtime"
  New-ReducerOwnershipRecord $detachedRuntime $detachedWorktree | Out-Null
  Invoke-TestGit $detachedWorktree @("checkout", "--detach") | Out-Null
  $detachedOwners = Get-LiveDispatchOwnership $detachedRuntime $providerTemp $container
  Assert-True ($detachedOwners.health.status -eq "ok" -and
    @($detachedOwners.activeLanes).Count -eq 1 -and
    $null -eq $detachedOwners.activeLanes[0].branch) "transient detached HEAD retains a branch-mode owner and publishes branch=null"
  Invoke-TestGit $detachedWorktree @("switch", "-c", "codex/issue-6292-after-rebase") | Out-Null
  $reattachedOwners = Get-LiveDispatchOwnership $detachedRuntime $providerTemp $container
  Assert-True ($reattachedOwners.health.status -eq "ok" -and
    $reattachedOwners.activeLanes[0].branch -ceq "codex/issue-6292-after-rebase") "day-after branch reattachment remains a clean live steady state"
  $exitedOwners = Get-LiveDispatchOwnership $detachedRuntime $providerTemp $container `
    -ProcessStateResolver { param($ProcessId, $StartIdentity) "dead" }
  Assert-True ($exitedOwners.health.status -eq "ok" -and
    @($exitedOwners.activeLanes).Count -eq 0 -and
    $exitedOwners.health.counts.inactive -eq 1) "live to advanced to detached to branch to owner-exit returns clean ok steady state"

  $reviewWorktree = Add-ControlWorktree $identityMain "review-head-control" "" -Detached
  $reviewRuntime = New-ControlRuntime "immutable-review-runtime"
  $reviewRecord = New-ReducerOwnershipRecord $reviewRuntime $reviewWorktree "review" "immutable-head" $null
  $reviewOwners = Get-LiveDispatchOwnership $reviewRuntime $providerTemp $container
  Assert-True ($reviewOwners.health.status -eq "ok" -and
    @($reviewOwners.activeLanes).Count -eq 1 -and
    $null -eq $reviewOwners.activeLanes[0].branch) "immutable-head owner is active on its detached exact launch head"
  Invoke-TestGit $reviewWorktree @("commit", "--allow-empty", "-m", "move immutable review head") | Out-Null
  $movedReview = Get-LiveDispatchOwnership $reviewRuntime $providerTemp $container
  Assert-True ($movedReview.health.status -eq "partial" -and
    @($movedReview.activeLanes).Count -eq 0 -and
    @($movedReview.health.diagnostics | Where-Object { $_.code -ceq "worktree-identity-mismatch" }).Count -eq 1) "immutable-head owner is dropped when HEAD moves"
  Invoke-TestGit $reviewWorktree @("reset", "--hard", $reviewRecord.record.head) | Out-Null
  Invoke-TestGit $reviewWorktree @("switch", "-c", "review/incorrectly-branched") | Out-Null
  $branchedReview = Get-LiveDispatchOwnership $reviewRuntime $providerTemp $container
  Assert-True ($branchedReview.health.status -eq "partial" -and
    @($branchedReview.activeLanes).Count -eq 0) "immutable-head owner is dropped when its worktree gains a branch"

  $pathWorktree = Add-ControlWorktree $identityMain "lane-04" "codex/issue-6292-paths"
  $pathRuntime = New-ControlRuntime "canonical-path-runtime"
  New-ReducerOwnershipRecord $pathRuntime $pathWorktree | Out-Null
  $aliasRoot = Join-Path $root "aliases"
  New-Item -ItemType Directory -Path $aliasRoot | Out-Null
  $junction = Join-Path $aliasRoot "lane-04"
  New-Item -ItemType Junction -Path $junction -Target $pathWorktree | Out-Null
  $junctionRuntime = New-ControlRuntime "junction-path-runtime"
  New-ReducerOwnershipRecord $junctionRuntime $junction | Out-Null
  $junctionOwners = Get-LiveDispatchOwnership $junctionRuntime $providerTemp $container
  if ($PSVersionTable.PSEdition -ceq "Core") {
    Assert-True ($junctionOwners.health.status -eq "ok" -and
      @($junctionOwners.activeLanes).Count -eq 1) "junction spelling resolves to the same canonical worktree"
  } else {
    Assert-True ($junctionOwners.health.status -eq "partial" -and
      @($junctionOwners.activeLanes).Count -eq 0) "Windows PowerShell 5.1 Resolve-Path fallback rejects an unprovable junction identity"
    Write-Output "JUNCTION_CONTROL Windows PowerShell 5.1 fallback fails closed; final-path equivalence covered by pwsh suite"
  }
  $symlink = Join-Path $aliasRoot "lane-04-symlink"
  $symlinkAvailable = $true
  try {
    New-Item -ItemType SymbolicLink -Path $symlink -Target $pathWorktree -ErrorAction Stop | Out-Null
  } catch {
    $symlinkAvailable = $false
  }
  if ($symlinkAvailable) {
    Assert-True ((Get-DispatchCanonicalExistingPath $symlink) -ceq
      (Get-DispatchCanonicalExistingPath $pathWorktree)) "symbolic-link spelling resolves to the same canonical worktree"
  } elseif ($PSVersionTable.PSEdition -ceq "Core") {
    throw "ASSERTION FAILED: PowerShell Core symbolic-link control must be available"
  } else {
    Write-Output "SYMLINK_CONTROL Windows PowerShell 5.1 lacks unprivileged symlink creation; covered by pwsh suite"
  }
  if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT -and
      $PSVersionTable.PSEdition -ceq "Core") {
    $shortProgramFiles = "C:\PROGRA~1"
    $longProgramFiles = "C:\Program Files"
    Assert-True ((Test-Path -LiteralPath $shortProgramFiles) -and
      (Get-DispatchCanonicalExistingPath $shortProgramFiles) -ceq
      (Get-DispatchCanonicalExistingPath $longProgramFiles)) "8.3 short-name spelling resolves to the same canonical filesystem path"
  } elseif ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
    Write-Output "SHORT_PATH_CONTROL Windows PowerShell 5.1 fallback fails closed; 8.3 equivalence covered by pwsh suite"
  }

  $outsideParent = Join-Path $root "outside-container"
  New-Item -ItemType Directory -Path $outsideParent | Out-Null
  $outsideWorktree = Join-Path $outsideParent "outside-owner"
  Invoke-TestGit $identityMain @("worktree", "add", "-b", "codex/outside", $outsideWorktree, "HEAD") | Out-Null
  $outsideRuntime = New-ControlRuntime "outside-runtime"
  New-ReducerOwnershipRecord $outsideRuntime $outsideWorktree | Out-Null
  $outsideOwners = Get-LiveDispatchOwnership $outsideRuntime $providerTemp $container
  Assert-True ($outsideOwners.health.status -eq "partial" -and
    @($outsideOwners.activeLanes).Count -eq 0 -and
    @($outsideOwners.health.diagnostics | Where-Object { $_.code -ceq "worktree-outside-container" }).Count -eq 1) "a live owner outside the canonical container is rejected"

  $mismatchOwners = Get-LiveDispatchOwnership $pathRuntime $providerTemp $container `
    -GitIdentityResolver {
      param($Worktree)
      [pscustomobject]@{
        status = "ok"
        worktree = $advancedWorktree
        branch = "codex/issue-6292-paths"
        head = (Invoke-TestGit $Worktree @("rev-parse", "HEAD")).ToLowerInvariant()
      }
    }
  Assert-True ($mismatchOwners.health.status -eq "partial" -and
    @($mismatchOwners.activeLanes).Count -eq 0 -and
    @($mismatchOwners.health.diagnostics | Where-Object { $_.code -ceq "worktree-identity-mismatch" }).Count -eq 1) "a git top-level resolving to a different canonical worktree is rejected"

  $duplicateWorktree = Add-ControlWorktree $identityMain "lane-05" "codex/issue-6292-duplicate"
  $duplicateRuntime = New-ControlRuntime "duplicate-runtime"
  New-ReducerOwnershipRecord $duplicateRuntime $duplicateWorktree -LaunchId "00000000-0000-0000-0000-000000000001" | Out-Null
  New-ReducerOwnershipRecord $duplicateRuntime $duplicateWorktree -LaunchId "ffffffff-ffff-ffff-ffff-ffffffffffff" | Out-Null
  $duplicateOwners = Get-LiveDispatchOwnership $duplicateRuntime $providerTemp $container
  Assert-True ($duplicateOwners.health.status -eq "partial" -and
    @($duplicateOwners.activeLanes).Count -eq 1 -and
    @($duplicateOwners.health.diagnostics | Where-Object { $_.code -ceq "duplicate-live-ownership" }).Count -eq 1) "two live records for one canonical worktree collapse to one and diagnose duplicate ownership"

  foreach ($liveFirst in @($true, $false)) {
    $mixedRuntime = New-ControlRuntime ("mixed-runtime-" + $liveFirst)
    $firstStart = if ($liveFirst) { $currentStart } else { "2000-01-01T00:00:00.0000000Z" }
    $secondStart = if ($liveFirst) { "2000-01-01T00:00:00.0000000Z" } else { $currentStart }
    New-ReducerOwnershipRecord $mixedRuntime $duplicateWorktree -ChildStartIdentity $firstStart `
      -LaunchId "00000000-0000-0000-0000-000000000002" | Out-Null
    New-ReducerOwnershipRecord $mixedRuntime $duplicateWorktree -ChildStartIdentity $secondStart `
      -LaunchId "ffffffff-ffff-ffff-ffff-ffffffffffff" | Out-Null
    $mixedOwners = Get-LiveDispatchOwnership $mixedRuntime $providerTemp $container
    Assert-True ($mixedOwners.health.status -eq "ok" -and
      @($mixedOwners.activeLanes).Count -eq 1 -and
      $mixedOwners.health.counts.inactive -eq 1) "one live plus one dead record retains exactly the live owner in both record orders ($liveFirst)"
  }

  $pidRuntime = New-ControlRuntime "pid-reuse-runtime"
  New-ReducerOwnershipRecord $pidRuntime $duplicateWorktree `
    -ChildStartIdentity "2000-01-01T00:00:00.0000000Z" | Out-Null
  $pidOwners = Get-LiveDispatchOwnership $pidRuntime $providerTemp $container
  Assert-True ($pidOwners.health.status -eq "ok" -and
    @($pidOwners.activeLanes).Count -eq 0 -and
    $pidOwners.health.counts.inactive -eq 1) "a reused live PID with a different start identity is not the owner"

  $malformedLiveWorktree = Add-ControlWorktree $identityMain "lane-10-predecessor-proof" "codex/malformed-live"
  $malformedLiveRuntime = New-ControlRuntime "malformed-live-runtime"
  New-ReducerOwnershipRecord $malformedLiveRuntime $malformedLiveWorktree | Out-Null
  $malformedLiveOwners = Get-LiveDispatchOwnership $malformedLiveRuntime $providerTemp $container
  Assert-True ($malformedLiveOwners.health.status -eq "partial" -and
    @($malformedLiveOwners.activeLanes).Count -eq 0 -and
    @($malformedLiveOwners.health.diagnostics | Where-Object {
        $_.code -ceq "malformed-live-lane-name" -and $_.lane -ceq "lane-10-predecessor-proof"
      }).Count -eq 1) "a validated live owner in a malformed lane-* directory is blocking and never active"

  $caseVariantLiveWorktree = Add-ControlWorktree $identityMain "LANE-99" "codex/case-variant-live"
  $caseVariantLiveRuntime = New-ControlRuntime "case-variant-live-runtime"
  New-ReducerOwnershipRecord $caseVariantLiveRuntime $caseVariantLiveWorktree | Out-Null
  $caseVariantLiveOwners = Get-LiveDispatchOwnership $caseVariantLiveRuntime $providerTemp $container
  Assert-True ($caseVariantLiveOwners.health.status -eq "partial" -and
    @($caseVariantLiveOwners.activeLanes).Count -eq 0 -and
    @($caseVariantLiveOwners.health.diagnostics | Where-Object {
        $_.code -ceq "malformed-live-lane-name" -and $_.lane -ceq "LANE-99"
      }).Count -eq 1) "a validated live owner in a case-variant lane-* directory is blocking and never active"

  $invalidRuntime = New-ControlRuntime "invalid-record-runtime"
  [IO.File]::WriteAllText(
    (Join-Path $invalidRuntime "dispatch-launch-00000000-0000-0000-0000-000000000003.json"),
    "{not-json}",
    [Text.UTF8Encoding]::new($false)
  )
  $invalidOwners = Get-LiveDispatchOwnership $invalidRuntime $providerTemp $container
  Assert-True ($invalidOwners.health.status -eq "partial" -and
    @($invalidOwners.health.diagnostics | Where-Object { $_.code -ceq "ownership-record-invalid" }).Count -eq 1) "invalid ownership record independently degrades health"

  $missingRuntime = Join-Path $root "missing-runtime"
  $enumerationOwners = Get-LiveDispatchOwnership $missingRuntime $providerTemp $container
  Assert-True ($enumerationOwners.health.status -eq "partial" -and
    @($enumerationOwners.health.diagnostics | Where-Object { $_.code -ceq "ownership-enumeration-failed" }).Count -eq 1) "ownership enumeration failure independently degrades health"

  $capRuntime = New-ControlRuntime "record-cap-runtime"
  New-ReducerOwnershipRecord $capRuntime $duplicateWorktree `
    -LaunchId "00000000-0000-0000-0000-000000000004" | Out-Null
  New-ReducerOwnershipRecord $capRuntime $pathWorktree `
    -LaunchId "00000000-0000-0000-0000-000000000005" | Out-Null
  $capOwners = Get-LiveDispatchOwnership $capRuntime $providerTemp $container -MaxRecords 1
  $capDiagnostic = @($capOwners.health.diagnostics | Where-Object { $_.code -ceq "ownership-record-cap-truncated" })
  Assert-True ($capOwners.health.status -eq "partial" -and
    $capOwners.health.counts.truncated -eq 1 -and
    $capDiagnostic.Count -eq 1 -and
    $capDiagnostic[0].unexamined -eq 1 -and
    $capDiagnostic[0].unexaminedIsLowerBound -eq $true) "record-cap truncation names its proven unexamined lower bound and degrades health"

  $deadlineRuntime = New-ControlRuntime "deadline-runtime"
  New-ReducerOwnershipRecord $deadlineRuntime $duplicateWorktree | Out-Null
  $deadlineOwners = Get-LiveDispatchOwnership $deadlineRuntime $providerTemp $container -DeadlineMs 0
  $deadlineDiagnostic = @($deadlineOwners.health.diagnostics | Where-Object { $_.code -ceq "ownership-deadline-truncated" })
  Assert-True ($deadlineOwners.health.status -eq "partial" -and
    $deadlineOwners.health.counts.truncated -eq 1 -and
    $deadlineDiagnostic.Count -eq 1 -and
    $deadlineDiagnostic[0].unexamined -eq 1) "deadline truncation names the exact unexamined count and degrades health"

  $warmTranscriptProbe = [pscustomobject]@{
    calls = 0
    existed = $false
    state = $null
  }
  $warmDateKindSupported = (Get-Command ConvertFrom-Json).Parameters.ContainsKey("DateKind")
  Initialize-DispatchOwnershipRecordProbe $providerTemp $warmDateKindSupported `
    -TranscriptProbeObserver {
      param($TranscriptPath, $AttemptState)
      $warmTranscriptProbe.calls += 1
      $warmTranscriptProbe.existed = Test-Path -LiteralPath $TranscriptPath -PathType Leaf
      $warmTranscriptProbe.state = [string]$AttemptState.state
    }
  Assert-True ($warmTranscriptProbe.calls -eq 1 -and
    $warmTranscriptProbe.existed -and
    $warmTranscriptProbe.state -ceq "active") "cold initialization creates and parses one representative transcript before returning"

  $probeRuntime = New-ControlRuntime "probe-runtime"
  New-ReducerOwnershipRecord $probeRuntime $pathWorktree | Out-Null
  $processProbeOwners = Get-LiveDispatchOwnership $probeRuntime $providerTemp $container `
    -ProcessStateResolver { param($ProcessId, $StartIdentity) "failed" }
  Assert-True ($processProbeOwners.health.status -eq "partial" -and
    @($processProbeOwners.health.diagnostics | Where-Object { $_.code -ceq "process-identity-probe-failed" }).Count -eq 1) "process identity probe failure independently degrades health"
  $gitProbeOwners = Get-LiveDispatchOwnership $probeRuntime $providerTemp $container `
    -GitIdentityResolver { param($Worktree) throw "injected git probe failure" }
  Assert-True ($gitProbeOwners.health.status -eq "partial" -and
    @($gitProbeOwners.health.diagnostics | Where-Object { $_.code -ceq "worktree-identity-probe-failed" }).Count -eq 1) "worktree identity probe failure independently degrades health"

  $resolutionRuntime = New-ControlRuntime "single-resolution-runtime"
  $candidateWorktrees = [Collections.Generic.HashSet[string]]::new(
    [StringComparer]::OrdinalIgnoreCase
  )
  foreach ($number in 20..24) {
    $lane = "lane-$number"
    $candidateWorktree = Join-Path $container $lane
    New-Item -ItemType Directory -Path $candidateWorktree | Out-Null
    [void]$candidateWorktrees.Add((Get-DispatchCanonicalRoot $candidateWorktree))
    New-ReducerOwnershipRecord -ControlRuntime $resolutionRuntime `
      -Worktree $candidateWorktree -RecordedBranch "control/single-resolution" `
      -RecordedHead ("c" * 40) | Out-Null
  }
  $resolutionCounts = @{}
  $dateKindProbe = [pscustomobject]@{ count = 0 }
  $countingCanonicalObserver = {
    param($Path, $ResolvedPath)
    $key = Get-DispatchCanonicalRoot ([string]$Path)
    if ($candidateWorktrees.Contains($key)) {
      if (-not $resolutionCounts.ContainsKey($key)) { $resolutionCounts[$key] = 0 }
      $resolutionCounts[$key] += 1
    }
  }
  $countingDateKindResolver = {
    $dateKindProbe.count += 1
    (Get-Command ConvertFrom-Json).Parameters.ContainsKey("DateKind")
  }
  $countedOwners = Get-LiveDispatchOwnership $resolutionRuntime $providerTemp $container `
    -ProcessStateResolver { param($ProcessId, $StartIdentity) "live" } `
    -GitIdentityResolver {
      param($Worktree)
      [pscustomobject]@{
        status = "ok"
        worktree = $Worktree
        branch = "control/single-resolution"
        head = "c" * 40
      }
    } -CanonicalPathObserver $countingCanonicalObserver `
    -DateKindSupportResolver $countingDateKindResolver
  Assert-True ($countedOwners.health.status -ceq "ok" -and
    $countedOwners.health.counts.examined -eq 5) "instrumented five-record fixture remains fully examined"
  Assert-True ($resolutionCounts.Count -eq 5 -and
    @($resolutionCounts.Values | Where-Object { $_ -ne 1 }).Count -eq 0) "each candidate-record worktree receives exactly one final-path resolution"
  Assert-True ($dateKindProbe.count -eq 1) "DateKind support is resolved once per invocation and never per record"
  Write-Output ("PROBE_COUNTS " + ([ordered]@{
        candidatePaths = $resolutionCounts
        finalPathCalls = ($resolutionCounts.Values | Measure-Object -Sum).Sum
        dateKindInvocationProbes = $dateKindProbe.count
        dateKindPerRecordProbes = 0
      } | ConvertTo-Json -Compress -Depth 4))

  # #6289 attempt authority: materialize minimized provider-envelope fixtures
  # beneath this isolated test root. Machine-local transcripts are diagnostic
  # evidence, not mutable fixture authority.
  function Write-AttemptLines([string]$Path, [object[]]$Lines) {
    [IO.File]::WriteAllText(
      $Path,
      ((@($Lines) -join "`n") + "`n"),
      [Text.UTF8Encoding]::new($false)
    )
  }

  $midClaudePath = Join-Path $root "ac01-midattempt-claude-result.jsonl"
  Write-AttemptLines $midClaudePath @(
    '{"type":"system","subtype":"init"}',
    '{"type":"assistant"}',
    '{"type":"result","subtype":"success"}',
    '{"type":"system","subtype":"init"}',
    '{"type":"assistant"}',
    '{"type":"user"}',
    '{"type":"assistant"}',
    '{"type":"assistant"}'
  )
  $midClaude = Get-DispatchAttemptState $midClaudePath
  Assert-True ($midClaude.state -ceq "active" -and
    $midClaude.completeRows -eq 8) "ac01-midattempt-claude-result"

  $midCodexPath = Join-Path $root "ac02-midattempt-codex-turn-completed.jsonl"
  Write-AttemptLines $midCodexPath @(
    '{"type":"turn.completed"}',
    '{"type":"item.completed"}',
    '{"type":"item.started"}',
    '{"type":"item.completed"}',
    '{"type":"item.started"}',
    '{"type":"item.completed"}',
    '{"type":"item.started"}'
  )
  $midCodex = Get-DispatchAttemptState $midCodexPath
  Assert-True ($midCodex.state -ceq "active" -and
    $midCodex.completeRows -eq 7) "ac02-midattempt-codex-turn-completed"

  $finalClaudePath = Join-Path $root "ac03-final-terminal-live-child.jsonl"
  Write-AttemptLines $finalClaudePath @(
    '{"type":"system","subtype":"init"}',
    '{"type":"assistant"}',
    '{"type":"result","subtype":"success"}'
  )
  $finalClaude = Get-DispatchAttemptState $finalClaudePath
  Assert-True ($finalClaude.state -ceq "terminal" -and
    $finalClaude.reason -ceq "final-row-terminal") "ac03-final-terminal-live-child"

  $codexLiveTranscript = Join-Path $root "ac06-codex-malformed-interior.jsonl"
  $codexPrefix = '{"type":"diagnostic","payload":"' + ("p" * 1100000) + '"}'
  $codexRows = @($codexPrefix)
  foreach ($index in 1..28) {
    $codexRows += $(if ($index -eq 13) {
      '{"type":'
    } elseif ($index -eq 28) {
      '{"type":"turn.completed"}'
    } else {
      '{"type":"item.completed"}'
    })
  }
  Write-AttemptLines $codexLiveTranscript $codexRows
  $expectedCodexWindowStart = [Text.Encoding]::UTF8.GetByteCount(
    (($codexRows -join "`n") + "`n")
  ) - 1048576
  $realMalformed = Get-DispatchAttemptState $codexLiveTranscript
  Assert-True ($realMalformed.state -ceq "terminal" -and
    $realMalformed.malformedRows -eq 1 -and
    $realMalformed.completeRows -eq 28 -and
    $realMalformed.windowStartByte -eq $expectedCodexWindowStart) "ac06-real-malformed-interior"

  $finalMalformedPath = Join-Path $root "ac07-final-row-malformed.jsonl"
  Write-AttemptLines $finalMalformedPath @('{"type":"item.completed"}', '{"type":')
  $finalMalformed = Get-DispatchAttemptState $finalMalformedPath
  Assert-True ($finalMalformed.state -ceq "unknown" -and
    $finalMalformed.reason -ceq "final-row-malformed") "ac07-final-row-malformed"

  $densityTripPath = Join-Path $root "ac08-density-trips.jsonl"
  $densityTripRows = @()
  foreach ($index in 1..19) {
    $densityTripRows += $(if ($index -le 10) { "not-json-$index" } else { '{"type":"item.completed"}' })
  }
  $densityTripRows += '{"type":"item.completed"}'
  Write-AttemptLines $densityTripPath $densityTripRows
  $densityTrip = Get-DispatchAttemptState $densityTripPath
  Assert-True ($densityTrip.state -ceq "unknown" -and
    $densityTrip.reason -ceq "malformed-density" -and
    $densityTrip.completeRows -eq 20 -and
    $densityTrip.malformedRows -eq 10) "ac08-density-trips"

  $densityHoldPath = Join-Path $root "ac08-density-holds.jsonl"
  $densityHoldRows = @("bad-1", "bad-2", "bad-3")
  foreach ($index in 4..20) { $densityHoldRows += '{"type":"item.completed"}' }
  Write-AttemptLines $densityHoldPath $densityHoldRows
  $densityHold = Get-DispatchAttemptState $densityHoldPath
  Assert-True ($densityHold.state -ceq "active" -and
    $densityHold.malformedRows -eq 3 -and
    $densityHold.completeRows -eq 20) "ac08-density-holds"

  $boundedDensityPath = Join-Path $root "ac08-bounded-density-suffix.jsonl"
  $boundedDensityRows = @("bad-outside-suffix")
  foreach ($index in 1..64) { $boundedDensityRows += '{"type":"item.completed"}' }
  Write-AttemptLines $boundedDensityPath $boundedDensityRows
  $boundedDensity = Get-DispatchAttemptState $boundedDensityPath
  Assert-True ($boundedDensity.state -ceq "active" -and
    $boundedDensity.completeRows -eq 64 -and
    $boundedDensity.malformedRows -eq 0) "malformed-density parsing is bounded to the authoritative 64-row suffix sample"

  $rowlessPath = Join-Path $root "ac09-window-holds-no-complete-row.jsonl"
  [IO.File]::WriteAllText($rowlessPath, ("x" * 2103802), [Text.UTF8Encoding]::new($false))
  $rowless = Get-DispatchAttemptState $rowlessPath
  Assert-True ($rowless.state -ceq "unknown" -and
    $rowless.reason -ceq "window-holds-no-complete-row") "ac09-window-holds-no-complete-row"

  $utf8Path = Join-Path $root "ac10-utf8-window-alignment.jsonl"
  $utf8Scalar = [char]::ConvertFromUtf32(0x1F600)
  [IO.File]::WriteAllText(
    $utf8Path,
    "x$utf8Scalar`n{`"type`":`"turn.completed`"}`n",
    [Text.UTF8Encoding]::new($false)
  )
  $utf8Length = (Get-Item -LiteralPath $utf8Path).Length
  $utf8Inside = Get-DispatchAttemptState $utf8Path -MaxTailBytes ($utf8Length - 3)
  $utf8Lead = Get-DispatchAttemptState $utf8Path -MaxTailBytes ($utf8Length - 1)
  Assert-True ($utf8Inside.windowStartByte -eq 5 -and
    $utf8Inside.state -ceq "terminal" -and
    $utf8Lead.state -ceq $utf8Inside.state) "ac10-utf8-window-alignment"

  $missingPath = Join-Path $root "ac11-transcript-missing.jsonl"
  $missingAttempt = Get-DispatchAttemptState $missingPath
  Assert-True ($missingAttempt.state -ceq "unknown" -and
    $missingAttempt.reason -ceq "transcript-missing") "ac11-transcript-missing"
  $deletedPath = Join-Path $root "ac11-transcript-deleted-midsnapshot.jsonl"
  Write-AttemptLines $deletedPath @('{"type":"item.completed"}')
  Remove-Item -LiteralPath $deletedPath
  $deletedAttempt = Get-DispatchAttemptState $deletedPath
  Assert-True ($deletedAttempt.state -ceq "unknown" -and
    $deletedAttempt.reason -ceq "transcript-missing") "ac11-transcript-deleted-midsnapshot"

  $growthPath = Join-Path $root "ac12-growth-during-snapshot.jsonl"
  Write-AttemptLines $growthPath @('{"type":"item.completed"}')
  $growthObserver = {
    param($Stream, $CapturedLength)
    [IO.File]::AppendAllText(
      $growthPath,
      "{`"type`":`"turn.completed`"}`n",
      [Text.UTF8Encoding]::new($false)
    )
  }.GetNewClosure()
  $growthFirst = Get-DispatchAttemptState $growthPath -StreamOpenedObserver $growthObserver
  $growthSecond = Get-DispatchAttemptState $growthPath
  Assert-True ($growthFirst.state -ceq "active" -and
    $growthSecond.state -ceq "terminal") "ac12-growth-during-snapshot"

  $largeDiagnosticPath = Join-Path $root "whole-artifact-cap-control.jsonl"
  Write-AttemptLines $largeDiagnosticPath @(
    ('{"type":"diagnostic","text":"' + ("z" * 900000) + '"}'),
    '{"type":"turn.completed"}'
  )
  $largeDiagnostic = Get-DispatchAttemptState $largeDiagnosticPath
  Assert-True ($largeDiagnostic.state -ceq "terminal") "canonical terminal payload is bounded separately from unrelated transcript bulk"

  $oversizedCanonicalPath = Join-Path $root "oversized-canonical-row-control.jsonl"
  Write-AttemptLines $oversizedCanonicalPath @(
    ('{"type":"result","payload":"' + ("x" * 2103803) + '"}')
  )
  $oversizedCanonical = Get-DispatchAttemptState $oversizedCanonicalPath `
    -MaxTailBytes 2200000 -MaxCanonicalRowBytes 2103802
  Assert-True ($oversizedCanonical.state -ceq "unknown" -and
    $oversizedCanonical.reason -ceq "final-row-malformed") "MaxCanonicalRowBytes remains reachable when the caller tail can hold an oversized final row"

  $crlfPath = Join-Path $root "crlf-terminal-control.jsonl"
  [IO.File]::WriteAllText(
    $crlfPath,
    "{`"type`":`"item.completed`"}`r`n{`"type`":`"result`"}`r`n",
    [Text.UTF8Encoding]::new($false)
  )
  Assert-True ((Get-DispatchAttemptState $crlfPath).state -ceq "terminal") "CRLF last-complete-row terminal is accepted"
  $scalarPath = Join-Path $root "scalar-type-control.jsonl"
  Write-AttemptLines $scalarPath @('{"type":["result"]}')
  Assert-True ((Get-DispatchAttemptState $scalarPath).state -ceq "active") "terminal type must be an exact scalar string"
  Write-AttemptLines $scalarPath @('{"Type":"result"}')
  Assert-True ((Get-DispatchAttemptState $scalarPath).state -ceq "active") "terminal type property name is case-sensitive"

  $denseRuntime = New-ControlRuntime "dense-ceiling-runtime"
  $denseRow = '{"type":"item.completed","payload":"' + ("x" * 160) + '"}' + "`n"
  $denseText = $denseRow * [Math]::Floor(
    1048576 / [Text.Encoding]::UTF8.GetByteCount($denseRow)
  )
  $denseTranscripts = @()
  foreach ($number in 60..71) {
    $lane = "lane-$number"
    $denseWorktree = Join-Path $container $lane
    New-Item -ItemType Directory -Path $denseWorktree | Out-Null
    $denseRecord = New-ReducerOwnershipRecord $denseRuntime $denseWorktree `
      -RecordedBranch "control/dense-ceiling" -RecordedHead ("d" * 40)
    [IO.File]::WriteAllText(
      [string]$denseRecord.record.transcriptPath,
      $denseText,
      [Text.UTF8Encoding]::new($false)
    )
    $denseTranscripts += [string]$denseRecord.record.transcriptPath
  }
  $denseAttempt = Get-DispatchAttemptState $denseTranscripts[0]
  Assert-True ($denseAttempt.state -ceq "active" -and
    $denseAttempt.completeRows -eq 64 -and
    $denseAttempt.malformedRows -eq 0) "dense transcript parsing examines only the bounded suffix sample"
  $denseWatch = [Diagnostics.Stopwatch]::StartNew()
  $denseOwners = Get-LiveDispatchOwnership $denseRuntime $providerTemp $container `
    -DeadlineMs 5000 `
    -ProcessStateResolver { param($ProcessId, $StartIdentity) "live" } `
    -GitIdentityResolver {
      param($Worktree)
      [pscustomobject]@{
        status = "ok"
        worktree = $Worktree
        branch = "control/dense-ceiling"
        head = "d" * 40
      }
    }
  $denseWatch.Stop()
  Assert-True ($denseOwners.health.counts.candidates -eq 12 -and
    $denseOwners.health.counts.examined -eq 12 -and
    $denseOwners.health.counts.truncated -eq 0) "twelve dense schema-v4 owners complete within the inherited 5000ms deadline"
  Write-Output "DENSE_CEILING elapsedMs=$($denseWatch.ElapsedMilliseconds) examined=12/12 truncated=0"

  $attemptRuntime = New-ControlRuntime "attempt-authority-runtime"
  $attemptWorktree = Add-ControlWorktree $identityMain "lane-30" "control/attempt-authority"
  $attemptRecord = New-ReducerOwnershipRecord $attemptRuntime $attemptWorktree
  Copy-Item -LiteralPath $finalClaudePath -Destination $attemptRecord.record.transcriptPath -Force
  $liveTerminal = Get-LiveDispatchOwnership $attemptRuntime $providerTemp $container `
    -ProcessStateResolver { param($ProcessId, $StartIdentity) "live" }
  Assert-True ($liveTerminal.health.status -ceq "partial" -and
    $liveTerminal.health.counts.active -eq 1 -and
    $liveTerminal.health.counts.lingeringAttempts -eq 1 -and
    @($liveTerminal.activeLanes).Count -eq 1 -and
    @($liveTerminal.health.diagnostics | Where-Object {
      $_.code -ceq "terminal-transcript-live-process"
    }).Count -eq 1) "ac03-final-terminal-live-child retains occupancy"

  $attemptReadCount = [pscustomobject]@{ count = 0 }
  $ownerExited = Get-LiveDispatchOwnership $attemptRuntime $providerTemp $container `
    -ProcessStateResolver { param($ProcessId, $StartIdentity) "dead" } `
    -AttemptStateResolver {
      param($TranscriptPath)
      $attemptReadCount.count += 1
      throw "dead owners must not read transcripts"
    }
  Assert-True ($ownerExited.health.status -ceq "ok" -and
    $ownerExited.health.counts.inactive -eq 1 -and
    @($ownerExited.activeLanes).Count -eq 0 -and
    $attemptReadCount.count -eq 0 -and
    @($ownerExited.health.diagnostics | Where-Object {
      $_.code -ceq "dispatch-owner-exited"
    }).Count -eq 1) "ac04-owner-exit-reclaims"

  Remove-Item -LiteralPath $attemptRecord.path
  $relaunched = New-ReducerOwnershipRecord $attemptRuntime $attemptWorktree
  $steadyState = Get-LiveDispatchOwnership $attemptRuntime $providerTemp $container `
    -ProcessStateResolver { param($ProcessId, $StartIdentity) "live" }
  Assert-True ($steadyState.health.status -ceq "ok" -and
    $steadyState.health.counts.active -eq 1 -and
    $steadyState.health.counts.lingeringAttempts -eq 0 -and
    @($steadyState.health.diagnostics).Count -eq 0) "ac16-steady-state-day-after"

  $duplicateRuntime = New-ControlRuntime "duplicate-transcript-runtime"
  $duplicateWorktreeA = Add-ControlWorktree $identityMain "lane-31" "control/transcript-a"
  $duplicateWorktreeB = Add-ControlWorktree $identityMain "lane-32" "control/transcript-b"
  $duplicateA = New-ReducerOwnershipRecord $duplicateRuntime $duplicateWorktreeA
  $duplicateB = New-ReducerOwnershipRecord $duplicateRuntime $duplicateWorktreeB
  $duplicateB.record.label = $duplicateA.record.label
  $duplicateB.record.transcriptPath = $duplicateA.record.transcriptPath
  Write-DispatchOwnershipRecord $duplicateB.path $duplicateB.record
  $duplicateProjection = Get-LiveDispatchOwnership $duplicateRuntime $providerTemp $container `
    -ProcessStateResolver { param($ProcessId, $StartIdentity) "live" }
  Assert-True ($duplicateProjection.health.status -ceq "partial" -and
    $duplicateProjection.health.counts.rejected -eq 1 -and
    @($duplicateProjection.health.diagnostics | Where-Object {
      $_.code -ceq "duplicate-live-transcript"
    }).Count -eq 1) "ac13-duplicate-live-transcript"

  $boundedRuntime = New-ControlRuntime "attempt-bounded-runtime"
  foreach ($number in 33..37) {
    $boundedWorktree = Add-ControlWorktree $identityMain ("lane-{0:d2}" -f $number) `
      ("control/attempt-bounded-$number")
    $boundedRecord = New-ReducerOwnershipRecord $boundedRuntime $boundedWorktree
    [IO.File]::WriteAllText(
      $boundedRecord.record.transcriptPath,
      (("x" * 1500000) + "`n{`"type`":`"item.completed`"}`n"),
      [Text.UTF8Encoding]::new($false)
    )
  }
  $boundedWatch = [Diagnostics.Stopwatch]::StartNew()
  $boundedProjection = Get-LiveDispatchOwnership $boundedRuntime $providerTemp $container `
    -ProcessStateResolver { param($ProcessId, $StartIdentity) "live" }
  $boundedWatch.Stop()
  Assert-True ($boundedProjection.health.status -ceq "ok" -and
    $boundedProjection.health.counts.examined -eq 5 -and
    $boundedProjection.health.counts.truncated -eq 0 -and
    $boundedProjection.health.counts.active -eq 5) "ac15-bounded-runtime examines five 1.5 MB attempts inside the inherited default deadline"
  Write-Output (
    "ATTEMPT_TIMING control=ac15-bounded-runtime owners=5 bytesEach=1500028 " +
    "elapsedMs=$($boundedWatch.Elapsed.TotalMilliseconds.ToString('F1', [Globalization.CultureInfo]::InvariantCulture)) " +
    "deadlineMs=5000 measurementOnly=true"
  )

  $schemaControl = New-TestOwnershipRecord
  $validSchemaV4 = Get-ValidatedDispatchOwnershipRecord $schemaControl.path $runtime $providerTemp
  Assert-True ($null -ne $validSchemaV4) "schema-v4 closed contract accepts its canonical payload"
  foreach ($schemaMutation in @(
      [pscustomobject]@{ name = "unknown-field"; apply = {
          param($r)
          $r | Add-Member -NotePropertyName extra `
            -NotePropertyValue ([pscustomobject]@{ nested = $true })
        } },
      [pscustomobject]@{ name = "string-pid"; apply = { param($r) $r.childPid = [string]$r.childPid } },
      [pscustomobject]@{ name = "loose-instant"; apply = { param($r) $r.recordedAt = "2026-07-29" } },
      [pscustomobject]@{ name = "label-leaf-mismatch"; apply = { param($r) $r.label = "different-label" } },
      [pscustomobject]@{ name = "relative-transcript"; apply = { param($r) $r.transcriptPath = "relative.jsonl" } },
      [pscustomobject]@{ name = "nested-type"; apply = { param($r) $r.childPid = [pscustomobject]@{ value = $r.childPid } } }
    )) {
    $mutated = ConvertFrom-DispatchOwnershipJson (
      $schemaControl.record | ConvertTo-Json -Depth 6
    )
    & $schemaMutation.apply $mutated
    Write-DispatchOwnershipRecord $schemaControl.path $mutated
    Assert-True ($null -eq (Get-ValidatedDispatchOwnershipRecord $schemaControl.path $runtime $providerTemp)) "schema-v4 malformed control $($schemaMutation.name) fails closed"
  }

  $severity = Get-LaneDiagnosticSeverityTable
  Assert-True ((Get-LaneHealthStatus @([ordered]@{ code = "synthetic-unclassified-code" })) -ceq "partial") "unclassified diagnostic codes fail closed"
  Assert-True ((Get-LaneHealthStatus @([ordered]@{ code = "Malformed-Lane-Name" })) -ceq "partial") "case-variant diagnostic codes fail closed under ordinal lookup"
  $emitterFiles = @((Join-Path $PSScriptRoot "dispatch-ownership.ps1"))
  $emittedCodes = @($emitterFiles | ForEach-Object {
      [regex]::Matches(
        [IO.File]::ReadAllText($_),
        'code\s*=\s*"(?<code>[a-z0-9-]+)"'
      ) | ForEach-Object { $_.Groups["code"].Value }
    } | Sort-Object -Unique)
  $declaredCodes = @($severity.Keys | Sort-Object)
  Assert-True (@(Compare-Object $emittedCodes $declaredCodes).Count -eq 0) "severity inventory exactly covers every diagnostic code emitted by the reducer"
  Write-Output ("SEVERITY_INVENTORY " + ([ordered]@{
      declared = $severity
      emitted = $emittedCodes
      unknownDefault = "blocking"
    } | ConvertTo-Json -Compress -Depth 4))

  Write-Output "PASS dispatch-ownership schema-v4 attempt authority, branch lifecycle, exact identity, confinement, severity, and boundedness coverage"
} finally {
  $rootResolved = [IO.Path]::GetFullPath($root)
  $tempResolved = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd("\", "/")
  if ((Split-Path -Parent $rootResolved).TrimEnd("\", "/") -ne $tempResolved -or
      (Split-Path -Leaf $rootResolved) -notlike "dispatch-ownership-test-*") {
    throw "refusing unsafe test cleanup target: $rootResolved"
  }
  Remove-Item -LiteralPath $rootResolved -Recurse -Force -ErrorAction SilentlyContinue
}

. (Join-Path $PSScriptRoot 'interrupted-integration-test-support.ps1')
# The candidate dispatcher resolves routing data under admission; like the
# other carrier consumers, observe the tracked routing fixture rather than the
# machine-local registry (#8580: ROUTING_DATA_MISSING on a fresh runner).
. (Join-Path $PSScriptRoot 'routing-data-test-support.ps1')
$routingTestScope = Enter-RoutingDataTestScope
try { Test-7963ResumeCarrier 'ownership' } finally { Exit-RoutingDataTestScope $routingTestScope }
