<#
.SYNOPSIS
Compare the exact #6292 predecessor and repaired ownership projections from one
frozen live observation, then prove lease.json, every live dispatch-launch
record, and flow-log.jsonl retain byte length, SHA-256, and mtime identity.
#>
[CmdletBinding()]
param(
  [string]$LiveContainerRoot = "D:\Users\ToddS\Source\Repos\chase-sets",
  [string]$PredecessorCommit = "e396120d26a766e467e0d01052939d6abf945e21"
)

$ErrorActionPreference = "Stop"
$liveRoot = [IO.Path]::GetFullPath($LiveContainerRoot).TrimEnd("\", "/")
$liveOrchestrator = Join-Path $liveRoot ".orchestrator"
$liveLease = Join-Path $liveOrchestrator "lease.json"
$liveFlowLog = Join-Path $liveOrchestrator "flow-log.jsonl"
$repository = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot)).TrimEnd("\", "/")
$tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd("\", "/")
$tempRoot = Join-Path $tempBase ("issue-6292-live-readonly-" + [guid]::NewGuid().ToString("N"))
$predecessorScript = Join-Path $tempRoot "dispatch-ownership.predecessor.ps1"
$result = $null
New-Item -ItemType Directory -Path $tempRoot | Out-Null

function Get-SharedFileHash([string]$Path) {
  $stream = [IO.File]::Open(
    $Path,
    [IO.FileMode]::Open,
    [IO.FileAccess]::Read,
    [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
  )
  $sha = [Security.Cryptography.SHA256]::Create()
  try {
    return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace("-", "")
  } finally {
    $sha.Dispose()
    $stream.Dispose()
  }
}

function Get-ConsistentFileState([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "required live proof file is missing: $Path"
  }
  foreach ($attempt in 1..3) {
    $before = Get-Item -LiteralPath $Path -Force
    $length = [long]$before.Length
    $mtimeTicks = [long]$before.LastWriteTimeUtc.Ticks
    $hash = Get-SharedFileHash $Path
    $after = Get-Item -LiteralPath $Path -Force
    if ($length -eq [long]$after.Length -and
        $mtimeTicks -eq [long]$after.LastWriteTimeUtc.Ticks) {
      return [pscustomobject][ordered]@{
        name = $after.Name
        fullName = $after.FullName
        length = $length
        sha256 = $hash
        mtimeTicks = $mtimeTicks
      }
    }
  }
  throw "live proof file moved during state capture: $Path"
}

function Get-LiveManifest {
  $dispatch = @(Get-ChildItem -LiteralPath $liveOrchestrator -File `
      -Filter "dispatch-launch-*.json" -ErrorAction Stop |
    Sort-Object Name |
    ForEach-Object { Get-ConsistentFileState $_.FullName })
  return [pscustomobject][ordered]@{
    lease = Get-ConsistentFileState $liveLease
    dispatch = $dispatch
    flowLog = Get-ConsistentFileState $liveFlowLog
  }
}

function Assert-StateIdentity([object]$Before, [object]$After, [string]$Label) {
  if ($Before.name -cne $After.name -or
      $Before.length -ne $After.length -or
      $Before.sha256 -cne $After.sha256 -or
      $Before.mtimeTicks -ne $After.mtimeTicks) {
    throw "live read-only proof failed: $Label length/hash/mtime changed"
  }
}

function Assert-ManifestIdentity([object]$Before, [object]$After) {
  Assert-StateIdentity $Before.lease $After.lease "lease.json"
  Assert-StateIdentity $Before.flowLog $After.flowLog "flow-log.jsonl"
  $beforeDispatch = @($Before.dispatch)
  $afterDispatch = @($After.dispatch)
  if ($beforeDispatch.Count -ne $afterDispatch.Count) {
    throw "live read-only proof failed: dispatch-launch record set changed"
  }
  for ($index = 0; $index -lt $beforeDispatch.Count; $index++) {
    Assert-StateIdentity $beforeDispatch[$index] $afterDispatch[$index] `
      $beforeDispatch[$index].name
  }
}

function Get-RecordKey([int]$ProcessId, [string]$StartIdentity) {
  return "$ProcessId|$StartIdentity"
}

function Get-WorktreeKey([string]$Path) {
  return [IO.Path]::GetFullPath($Path).TrimEnd("\", "/").ToLowerInvariant()
}

try {
  # Exact predecessor bytes from the tracked history fixture (#8580).
  . (Join-Path $PSScriptRoot "history-fixture.ps1")
  try {
    $predecessorText = Get-HistoryFixtureText $PredecessorCommit ".orchestrator/dispatch-ownership.ps1"
  } catch {
    throw "cannot materialize exact predecessor $PredecessorCommit ($($_.Exception.Message))"
  }
  [IO.File]::WriteAllText(
    $predecessorScript,
    $predecessorText,
    [Text.UTF8Encoding]::new($false)
  )

  $before = Get-LiveManifest
  $observationUtc = [DateTimeOffset]::UtcNow.ToString("o")
  $warmupBefore = @(Get-ChildItem -LiteralPath $tempBase -Directory `
      -Filter "dispatch-ownership-warmup-*" -ErrorAction SilentlyContinue |
    ForEach-Object { $_.FullName })

  . (Join-Path $PSScriptRoot "dispatch-ownership.ps1")
  $processStates = @{}
  $gitStates = @{}
  $recordTelemetry = @()
  foreach ($state in @($before.dispatch)) {
    $record = Get-ValidatedDispatchOwnershipRecord $state.fullName `
      $liveOrchestrator ([IO.Path]::GetTempPath())
    if ($null -eq $record) { continue }
    $ownerPid = if ($record.state -ceq "started") {
      [int]$record.childPid
    } else {
      [int]$record.launcherPid
    }
    $ownerStart = if ($record.state -ceq "started") {
      [string]$record.childStartIdentity
    } else {
      [string]$record.launcherStartIdentity
    }
    $processKey = Get-RecordKey $ownerPid $ownerStart
    if (-not $processStates.ContainsKey($processKey)) {
      $processStates[$processKey] = Get-DispatchProcessIdentityState $ownerPid $ownerStart
    }
    if ([int]$record.schemaVersion -eq 3) {
      $worktreeKey = Get-WorktreeKey ([string]$record.worktree)
      if (-not $gitStates.ContainsKey($worktreeKey)) {
        $gitStates[$worktreeKey] = Get-DispatchGitIdentity ([string]$record.worktree)
      }
      $gitState = $gitStates[$worktreeKey]
      $recordTelemetry += [pscustomobject][ordered]@{
        lane = [string]$record.lane
        identityMode = [string]$record.identityMode
        processState = [string]$processStates[$processKey]
        recordBranch = $(if ($null -eq $record.branch) { $null } else { [string]$record.branch })
        recordHead = [string]$record.head
        liveBranch = $(if ($null -eq $gitState -or
            [string]::IsNullOrWhiteSpace([string]$gitState.branch)) {
          $null
        } else { [string]$gitState.branch })
        liveHead = $(if ($null -eq $gitState) { $null } else { [string]$gitState.head })
        gitStatus = $(if ($null -eq $gitState) { "missing" } else { [string]$gitState.status })
      }
    }
  }

  $frozenProcessResolver = {
    param($ProcessId, $StartIdentity)
    $key = Get-RecordKey ([int]$ProcessId) ([string]$StartIdentity)
    if ($processStates.ContainsKey($key)) { return [string]$processStates[$key] }
    return "failed"
  }.GetNewClosure()
  $frozenGitResolver = {
    param($Worktree)
    $key = Get-WorktreeKey ([string]$Worktree)
    if ($gitStates.ContainsKey($key)) { return $gitStates[$key] }
    return [pscustomobject]@{
      status = "failed"
      worktree = $null
      branch = $null
      head = $null
    }
  }.GetNewClosure()

  $repairedProjection = Get-LiveDispatchOwnership `
    -RuntimeRoot $liveOrchestrator `
    -TempRoot ([IO.Path]::GetTempPath()) `
    -ContainerRoot $liveRoot `
    -ProcessStateResolver $frozenProcessResolver `
    -GitIdentityResolver $frozenGitResolver

  . $predecessorScript
  $predecessorProjection = Get-LiveDispatchOwnership `
    -RuntimeRoot $liveOrchestrator `
    -TempRoot ([IO.Path]::GetTempPath()) `
    -ContainerRoot $liveRoot `
    -ProcessStateResolver $frozenProcessResolver `
    -GitIdentityResolver $frozenGitResolver

  $after = Get-LiveManifest
  Assert-ManifestIdentity $before $after
  $warmupAfter = @(Get-ChildItem -LiteralPath $tempBase -Directory `
      -Filter "dispatch-ownership-warmup-*" -ErrorAction SilentlyContinue |
    ForEach-Object { $_.FullName })
  $newWarmupLeftovers = @(Compare-Object $warmupBefore $warmupAfter |
    Where-Object { $_.SideIndicator -ceq "=>" })
  if ($newWarmupLeftovers.Count -ne 0) {
    throw "live read-only proof found ownership warm-up leftovers"
  }

  $projectionEvidence = @()
  foreach ($telemetry in @($recordTelemetry | Where-Object {
        $_.identityMode -ceq "branch" -and $_.processState -ceq "live" -and
        $_.gitStatus -ceq "ok"
      })) {
    $retained = @($repairedProjection.activeLanes | Where-Object {
        $_.lane -ceq $telemetry.lane -and $_.identityMode -ceq "branch"
      })
    if ($retained.Count -gt 0) {
      if ($retained[0].branch -cne $telemetry.liveBranch -or
          $retained[0].head -cne $telemetry.liveHead) {
        throw "repaired live projection does not publish frozen Git identity for $($telemetry.lane)"
      }
    }
    $projectionEvidence += [pscustomobject][ordered]@{
      lane = $telemetry.lane
      retained = $retained.Count -gt 0
      recordBranch = $telemetry.recordBranch
      recordHead = $telemetry.recordHead
      liveBranch = $telemetry.liveBranch
      liveHead = $telemetry.liveHead
    }
  }

  $advancedOwners = @($recordTelemetry | Where-Object {
      $_.identityMode -ceq "branch" -and $_.processState -ceq "live" -and
      $_.gitStatus -ceq "ok" -and
      -not [string]::IsNullOrWhiteSpace([string]$_.liveBranch) -and
      $_.recordBranch -cne $_.liveBranch
    })
  if ($advancedOwners.Count -gt 0) {
    foreach ($advanced in $advancedOwners) {
      $predecessorMismatch = @($predecessorProjection.health.diagnostics |
        Where-Object {
          $_.code -ceq "worktree-identity-mismatch" -and
          $_.lane -ceq $advanced.lane
        }).Count -gt 0
      $repairedRetained = @($repairedProjection.activeLanes | Where-Object {
          $_.lane -ceq $advanced.lane -and
          $_.branch -ceq $advanced.liveBranch -and
          $_.head -ceq $advanced.liveHead
        }).Count -gt 0
      if (-not $predecessorMismatch -or -not $repairedRetained) {
        throw "advanced live-owner differential failed for $($advanced.lane)"
      }
    }
    $differential = [ordered]@{
      arm = "advanced-owner-exercised"
      lanes = @($advancedOwners | ForEach-Object { $_.lane })
      fixtureFallback = $false
    }
  } else {
    $differential = [ordered]@{
      arm = "no-advanced-owner-at-captured-instant"
      lanes = @()
      fixtureFallback = $true
      fixtureEvidence = "deterministic dispatch-ownership controls AC1-AC3"
    }
  }

  $result = [pscustomobject][ordered]@{
    schema = "issue-6292-live-readonly-proof/v1"
    proof = "PASS"
    predecessor = $PredecessorCommit
    observationUtc = $observationUtc
    frozenProcessIdentities = $processStates.Count
    frozenGitIdentities = $gitStates.Count
    predecessorProjection = $predecessorProjection
    repairedProjection = $repairedProjection
    branchHeadEvidence = $projectionEvidence
    conditionalDifferential = $differential
    invariants = [ordered]@{
      lease = [ordered]@{
        length = $after.lease.length
        sha256 = $after.lease.sha256
        mtimeTicks = $after.lease.mtimeTicks
      }
      dispatchLaunchCount = @($after.dispatch).Count
      dispatchLaunch = @($after.dispatch | ForEach-Object {
          [ordered]@{
            name = $_.name
            length = $_.length
            sha256 = $_.sha256
            mtimeTicks = $_.mtimeTicks
          }
        })
      flowLog = [ordered]@{
        length = $after.flowLog.length
        sha256 = $after.flowLog.sha256
        mtimeTicks = $after.flowLog.mtimeTicks
      }
      byteLengthHashMtimeIdentity = $true
      tempLeftovers = $null
    }
  }
} finally {
  $resolvedTemp = [IO.Path]::GetFullPath($tempRoot)
  if (-not $resolvedTemp.StartsWith(
      $tempBase + [IO.Path]::DirectorySeparatorChar,
      [StringComparison]::OrdinalIgnoreCase
    ) -or (Split-Path -Leaf $resolvedTemp) -notlike "issue-6292-live-readonly-*") {
    throw "refusing unsafe live-proof cleanup target: $resolvedTemp"
  }
  Remove-Item -LiteralPath $resolvedTemp -Recurse -Force -ErrorAction SilentlyContinue
}

if (Test-Path -LiteralPath $tempRoot) {
  throw "live read-only proof left temporary files at $tempRoot"
}
if ($null -eq $result) {
  throw "live read-only proof produced no result"
}
$result.invariants.tempLeftovers = 0
$result | ConvertTo-Json -Depth 8
