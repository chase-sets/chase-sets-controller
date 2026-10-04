<#
.SYNOPSIS
Compare #6289 predecessor and staged attempt-authority projections from one
guarded live record set, then prove the lease, ownership records, and flow log
retain byte length, SHA-256, and mtime identity with no temp leftovers.
#>
[CmdletBinding()]
param(
  [string]$LiveContainerRoot = "D:\Users\ToddS\Source\Repos\chase-sets",
  [string]$PredecessorCommit = "e396120d26a766e467e0d01052939d6abf945e21"
)

$ErrorActionPreference = "Stop"
$liveRoot = [IO.Path]::GetFullPath($LiveContainerRoot).TrimEnd("\", "/")
$liveOrchestrator = Join-Path $liveRoot ".orchestrator"
$repository = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot)).TrimEnd("\", "/")
if (-not (Test-Path -LiteralPath (Join-Path $repository ".git")) -and
    (Test-Path -LiteralPath (Join-Path (Split-Path -Parent $repository) ".git"))) {
  $repository = [IO.Path]::GetFullPath(
    (Split-Path -Parent $repository)
  ).TrimEnd("\", "/")
}
$tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd("\", "/")
$tempRoot = Join-Path $tempBase ("issue-6289-live-readonly-" + [guid]::NewGuid().ToString("N"))
$predecessorScript = Join-Path $tempRoot "dispatch-ownership.predecessor.ps1"
New-Item -ItemType Directory -Path $tempRoot | Out-Null

function Get-SharedHash([string]$Path) {
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

function Get-GuardedState([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "required guarded file is missing: $Path"
  }
  foreach ($attempt in 1..3) {
    $before = Get-Item -LiteralPath $Path -Force
    $length = [long]$before.Length
    $mtime = [long]$before.LastWriteTimeUtc.Ticks
    $hash = Get-SharedHash $Path
    $after = Get-Item -LiteralPath $Path -Force
    if ($length -eq [long]$after.Length -and
        $mtime -eq [long]$after.LastWriteTimeUtc.Ticks) {
      return [pscustomobject][ordered]@{
        name = $after.Name
        path = $after.FullName
        length = $length
        sha256 = $hash
        mtimeTicks = $mtime
      }
    }
  }
  throw "guarded file moved during capture: $Path"
}

function Get-LiveManifest {
  $records = @(Get-ChildItem -LiteralPath $liveOrchestrator -File `
      -Filter "dispatch-launch-*.json" -ErrorAction Stop |
    Sort-Object Name |
    ForEach-Object { Get-GuardedState $_.FullName })
  return [pscustomobject][ordered]@{
    lease = Get-GuardedState (Join-Path $liveOrchestrator "lease.json")
    records = $records
    flowLog = Get-GuardedState (Join-Path $liveOrchestrator "flow-log.jsonl")
  }
}

function Assert-StateIdentity($Before, $After, [string]$Label) {
  if ($Before.name -cne $After.name -or
      $Before.length -ne $After.length -or
      $Before.sha256 -cne $After.sha256 -or
      $Before.mtimeTicks -ne $After.mtimeTicks) {
    throw "$Label changed during live read-only proof"
  }
}

function Assert-ManifestIdentity($Before, $After) {
  Assert-StateIdentity $Before.lease $After.lease "lease.json"
  Assert-StateIdentity $Before.flowLog $After.flowLog "flow-log.jsonl"
  if (@($Before.records).Count -ne @($After.records).Count) {
    throw "dispatch-launch record enumeration changed during proof"
  }
  for ($index = 0; $index -lt @($Before.records).Count; $index++) {
    Assert-StateIdentity $Before.records[$index] $After.records[$index] `
      $Before.records[$index].name
  }
}

function Get-ProcessKey([int]$ProcessId, [string]$StartIdentity) {
  return "$ProcessId|$StartIdentity"
}

function Get-PathKey([string]$Path) {
  return [IO.Path]::GetFullPath($Path).TrimEnd("\", "/").ToLowerInvariant()
}

function Get-ProjectionEvidence($Projection) {
  return [pscustomobject][ordered]@{
    status = [string]$Projection.health.status
    active = @($Projection.activeLanes).Count
    candidates = $Projection.health.counts.candidates
    examined = $Projection.health.counts.examined
    truncated = $Projection.health.counts.truncated
    legacyLiveOwners = $Projection.health.counts.legacyLiveOwners
    lingeringAttempts = $Projection.health.counts.lingeringAttempts
    probeFailures = $Projection.health.counts.probeFailures
    diagnostics = @($Projection.health.diagnostics | ForEach-Object {
        [pscustomobject][ordered]@{
          code = [string]$_.code
          lane = $(if ($null -eq $_.lane) { $null } else { [string]$_.lane })
          reason = $(if ($null -eq $_.reason) { $null } else { [string]$_.reason })
        }
      })
    lanes = @($Projection.activeLanes | ForEach-Object {
        [pscustomobject][ordered]@{
          lane = [string]$_.lane
          identityMode = [string]$_.identityMode
          branch = $(if ($null -eq $_.branch) { $null } else { [string]$_.branch })
          head = [string]$_.head
        }
      })
  }
}

$completed = $false
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
  $recordNames = @($before.records | ForEach-Object { $_.name })
  if (@($recordNames | Sort-Object -Unique).Count -ne $recordNames.Count) {
    throw "live ownership enumeration contains duplicate names"
  }

  . (Join-Path $PSScriptRoot "dispatch-ownership.ps1")
  $processStates = @{}
  $gitStates = @{}
  $attemptStates = @{}
  foreach ($recordState in @($before.records)) {
    $record = Get-ValidatedDispatchOwnershipRecord $recordState.path `
      $liveOrchestrator ([IO.Path]::GetTempPath())
    if ($null -eq $record) { continue }
    $ownerProcessId = if ($record.state -ceq "started") {
      [int]$record.childPid
    } else {
      [int]$record.launcherPid
    }
    $start = if ($record.state -ceq "started") {
      [string]$record.childStartIdentity
    } else {
      [string]$record.launcherStartIdentity
    }
    $processKey = Get-ProcessKey $ownerProcessId $start
    if (-not $processStates.ContainsKey($processKey)) {
      $processStates[$processKey] = Get-DispatchProcessIdentityState $ownerProcessId $start
    }
    if ([int]$record.schemaVersion -in @(3, 4)) {
      $worktreeKey = Get-PathKey ([string]$record.worktree)
      if (-not $gitStates.ContainsKey($worktreeKey)) {
        $gitStates[$worktreeKey] = Get-DispatchGitIdentity ([string]$record.worktree)
      }
    }
    if ([int]$record.schemaVersion -eq 4) {
      $attemptKey = Get-PathKey ([string]$record.transcriptPath)
      if (-not $attemptStates.ContainsKey($attemptKey)) {
        $attemptStates[$attemptKey] = Get-DispatchAttemptState ([string]$record.transcriptPath)
      }
    }
  }

  $frozenProcess = {
    param($ProcessId, $StartIdentity)
    $key = Get-ProcessKey ([int]$ProcessId) ([string]$StartIdentity)
    if ($processStates.ContainsKey($key)) { return [string]$processStates[$key] }
    return "failed"
  }.GetNewClosure()
  $frozenGit = {
    param($Worktree)
    $key = Get-PathKey ([string]$Worktree)
    if ($gitStates.ContainsKey($key)) { return $gitStates[$key] }
    return [pscustomobject]@{
      status = "failed"; worktree = $null; branch = $null; head = $null
    }
  }.GetNewClosure()
  $frozenAttempt = {
    param($TranscriptPath)
    $key = Get-PathKey ([string]$TranscriptPath)
    if ($attemptStates.ContainsKey($key)) { return $attemptStates[$key] }
    return New-DispatchAttemptState "unknown" "transcript-unreadable" 0 0 0
  }.GetNewClosure()

  $repaired = Get-LiveDispatchOwnership `
    -RuntimeRoot $liveOrchestrator `
    -TempRoot ([IO.Path]::GetTempPath()) `
    -ContainerRoot $liveRoot `
    -ProcessStateResolver $frozenProcess `
    -GitIdentityResolver $frozenGit `
    -AttemptStateResolver $frozenAttempt

  . $predecessorScript
  $predecessor = Get-LiveDispatchOwnership `
    -RuntimeRoot $liveOrchestrator `
    -TempRoot ([IO.Path]::GetTempPath()) `
    -ContainerRoot $liveRoot `
    -ProcessStateResolver $frozenProcess `
    -GitIdentityResolver $frozenGit

  $after = Get-LiveManifest
  Assert-ManifestIdentity $before $after

  $predecessorEvidence = Get-ProjectionEvidence $predecessor
  $repairedEvidence = Get-ProjectionEvidence $repaired
  Write-Output "OBSERVATION recordEnumerationComplete=true records=$($recordNames.Count)"
  Write-Output ("PREDECESSOR " + ($predecessorEvidence | ConvertTo-Json -Compress -Depth 8))
  Write-Output ("REPAIRED " + ($repairedEvidence | ConvertTo-Json -Compress -Depth 8))
  foreach ($guarded in @($after.lease) + @($after.records) + @($after.flowLog)) {
    Write-Output (
      "GUARD name=$($guarded.name) length=$($guarded.length) " +
      "sha256=$($guarded.sha256) mtimeTicks=$($guarded.mtimeTicks) identical=true"
    )
  }
  $completed = $true
} finally {
  $resolved = [IO.Path]::GetFullPath($tempRoot)
  if ((Split-Path -Parent $resolved).TrimEnd("\", "/") -ne $tempBase -or
      (Split-Path -Leaf $resolved) -notlike "issue-6289-live-readonly-*") {
    throw "refusing unsafe live-proof cleanup: $resolved"
  }
  Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
}

if (Test-Path -LiteralPath $tempRoot) {
  throw "live read-only proof left temp artifacts: $tempRoot"
}
if (-not $completed) { throw "live read-only proof did not complete" }
Write-Output "TEMP_LEFTOVERS count=0"
Write-Output "PASS issue-6289 live read-only predecessor/repaired projection"
