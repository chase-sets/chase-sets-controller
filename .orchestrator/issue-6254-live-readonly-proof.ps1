<#
.SYNOPSIS
Run the production landing preflight against one live open PR with mutation
hard-disabled, then prove mutation-sensitive PR/issue/board/queue state did not
change during the read-only observation.
#>
[CmdletBinding()]
param(
  [int]$Pr,
  [string]$Repository = "chase-sets/chase-sets",
  [string]$LiveHistoryPath = "D:\Users\ToddS\Source\Repos\chase-sets\.orchestrator\dispatch-log.jsonl"
)

$ErrorActionPreference = "Stop"
if (-not $Pr) {
  $listed = gh pr list -R $Repository --state open --limit 1 --json number 2>$null |
    ConvertFrom-Json -DateKind String
  $Pr = [int]@($listed)[0].number
}
if ($Pr -lt 1) { throw "live read-only proof requires an observable open PR" }

function Invoke-ReadOnlyProcess([string]$Command, [string[]]$Arguments) {
  $resolved = Get-Command $Command -CommandType Application -ErrorAction Stop |
    Select-Object -First 1
  $start = [Diagnostics.ProcessStartInfo]::new()
  $start.FileName = $resolved.Source
  $start.UseShellExecute = $false
  $start.CreateNoWindow = $true
  $start.RedirectStandardOutput = $true
  $start.RedirectStandardError = $true
  foreach ($argument in $Arguments) { [void]$start.ArgumentList.Add($argument) }
  $process = [Diagnostics.Process]::new()
  $process.StartInfo = $start
  try {
    [void]$process.Start()
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    if ($process.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($stdout)) {
      throw "read-only '$Command $($Arguments -join ' ')' observation failed: $stderr"
    }
    return $stdout
  } finally {
    $process.Dispose()
  }
}

function Get-SnapshotHash([string[]]$Documents) {
  $canonical = $Documents -join "`n---snapshot-boundary---`n"
  [Convert]::ToHexString(
    [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($canonical))
  ).ToLowerInvariant()
}

function Get-ProviderSnapshot {
  $document = Invoke-ReadOnlyProcess "doctl" @(
    "kubernetes", "cluster", "list", "--output", "json"
  )
  Get-SnapshotHash @($document)
}

function Get-ClusterSnapshot {
  $namespaces = Invoke-ReadOnlyProcess "kubectl" @("get", "namespaces", "-o", "json") |
    ConvertFrom-Json -DateKind String -ErrorAction Stop
  $nodes = Invoke-ReadOnlyProcess "kubectl" @("get", "nodes", "-o", "json") |
    ConvertFrom-Json -DateKind String -ErrorAction Stop
  $workloads = Invoke-ReadOnlyProcess "kubectl" @(
      "get", "deployments,statefulsets,daemonsets", "-A", "-o", "json"
    ) | ConvertFrom-Json -DateKind String -ErrorAction Stop
  $desiredState = [ordered]@{
    namespaces = @($namespaces.items | ForEach-Object {
        [ordered]@{
          name = [string]$_.metadata.name
          uid = [string]$_.metadata.uid
          deletionTimestamp = [string]$_.metadata.deletionTimestamp
          finalizers = @($_.spec.finalizers | ForEach-Object { [string]$_ } | Sort-Object)
        }
      } | Sort-Object name)
    nodes = @($nodes.items | ForEach-Object {
        [ordered]@{
          name = [string]$_.metadata.name
          uid = [string]$_.metadata.uid
          generation = $_.metadata.generation
          labels = $_.metadata.labels
          spec = $_.spec
        }
      } | Sort-Object name)
    workloads = @($workloads.items | ForEach-Object {
        [ordered]@{
          kind = [string]$_.kind
          namespace = [string]$_.metadata.namespace
          name = [string]$_.metadata.name
          uid = [string]$_.metadata.uid
          generation = $_.metadata.generation
          deletionTimestamp = [string]$_.metadata.deletionTimestamp
          spec = $_.spec
        }
      } | Sort-Object kind, namespace, name)
  }
  Get-SnapshotHash @(($desiredState | ConvertTo-Json -Compress -Depth 100))
}

function Invoke-LiveReport {
  & (Join-Path $PSScriptRoot "landing-preflight.ps1") -Pr $Pr `
    -Repository $Repository -Action Report -MutationDisabled `
    -HistoryPath $LiveHistoryPath |
    ConvertFrom-Json -DateKind String
}

function Get-IssueBoardState([object[]]$ClosingIssues) {
  @($ClosingIssues | ForEach-Object {
      $number = [int]$_.number
      try {
        $issue = gh issue view $number -R $Repository `
          --json number,state,closed,closedAt,blockedBy,projectItems 2>$null |
          ConvertFrom-Json -DateKind String -ErrorAction Stop
        [ordered]@{
          number = $issue.number
          state = [string]$issue.state
          closed = [bool]$issue.closed
          closedAt = [string]$issue.closedAt
          blockedBy = @($issue.blockedBy | ForEach-Object {
              [ordered]@{ number = $_.number; state = [string]$_.state }
            } | Sort-Object number)
          projectItems = @($issue.projectItems | ForEach-Object {
              [ordered]@{
                title = [string]$_.title
                status = [string]$_.status.name
              }
            } | Sort-Object title, status)
        }
      } catch {
        [ordered]@{ number = $number; unobservable = $true }
      }
    } | Sort-Object number)
}

function Get-MutationSensitiveState($Report) {
  $pull = $Report.observations.initial.pr
  if ($null -eq $pull) { throw "live read-only proof could not observe PR #$Pr" }
  $state = [ordered]@{
    pr = [ordered]@{
      number = $pull.number
      state = [string]$pull.state
      isDraft = [bool]$pull.isDraft
      head = [string]$pull.head
      baseRefName = [string]$pull.baseRefName
      mergeQueueEntryId = [string]$pull.mergeQueueEntryId
    }
    issuesAndBoard = Get-IssueBoardState @($pull.closingIssues)
  }
  $canonical = $state | ConvertTo-Json -Compress -Depth 8
  $hash = [Convert]::ToHexString(
    [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($canonical))
  ).ToLowerInvariant()
  [pscustomobject][ordered]@{ value = $state; hash = $hash }
}

$providerBefore = Get-ProviderSnapshot
$clusterBefore = Get-ClusterSnapshot
$beforeReport = Invoke-LiveReport
$before = Get-MutationSensitiveState $beforeReport
$afterReport = Invoke-LiveReport
$after = Get-MutationSensitiveState $afterReport
$providerAfter = Get-ProviderSnapshot
$clusterAfter = Get-ClusterSnapshot
$mutationCount = [int]$beforeReport.mutationCount + [int]$afterReport.mutationCount
$unchanged = $before.hash -ceq $after.hash
$providerUnchanged = $providerBefore -ceq $providerAfter
$clusterUnchanged = $clusterBefore -ceq $clusterAfter
if ($mutationCount -ne 0) { throw "live read-only proof observed a mutation call" }
if (-not $unchanged) { throw "live read-only proof observed PR/issue/board/queue state movement during the proof window" }
if (-not $providerUnchanged) { throw "live read-only proof observed provider state movement during the proof window" }
if (-not $clusterUnchanged) { throw "live read-only proof observed cluster state movement during the proof window" }

[pscustomobject][ordered]@{
  schema = "landing-preflight-live-readonly-proof/v1"
  proof = "PASS"
  repository = $Repository
  pr = $Pr
  head = [string]$before.value.pr.head
  preflightStatus = [string]$beforeReport.status
  preflightReason = [string]$beforeReport.reason
  mutationHardDisabled = $true
  mutationCount = $mutationCount
  prUnchanged = $unchanged
  issueUnchanged = $unchanged
  boardUnchanged = $unchanged
  queueUnchanged = $unchanged
  providerMutationCommands = 0
  clusterMutationCommands = 0
  providerUnchanged = $providerUnchanged
  clusterUnchanged = $clusterUnchanged
  stateHashBefore = $before.hash
  stateHashAfter = $after.hash
  providerHashBefore = $providerBefore
  providerHashAfter = $providerAfter
  clusterHashBefore = $clusterBefore
  clusterHashAfter = $clusterAfter
} | ConvertTo-Json -Depth 6
