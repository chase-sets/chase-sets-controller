<#
.SYNOPSIS
Discriminate the #6289 cold-initialization and dense-tail deadline repairs.

.DESCRIPTION
The cold control launches fresh PowerShell processes with five schema-v4 owners
and the inherited 300ms review deadline. It also injects a deterministic
first-use parser delay into candidate and bypass variants so the initialization
boundary, rather than host speed, is the governing variable.

The dense control compares the candidate with the exact repair predecessor at
the sanctioned twelve-owner ceiling and inherited 5000ms production deadline.
#>
[CmdletBinding()]
param(
  [string]$RepositoryRoot,
  [string]$CandidateScript,
  [string]$PredecessorCommit = "1031c527aeb3705e7738f8d7a18cb7b04dba81f8",
  [Parameter(DontShow)][switch]$ColdChild,
  [Parameter(DontShow)][string]$ScriptPath
)

$ErrorActionPreference = "Stop"
$selfPath = [IO.Path]::GetFullPath($MyInvocation.MyCommand.Path)
$scriptRoot = Split-Path -Parent $selfPath
if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
  $RepositoryRoot = Split-Path -Parent $scriptRoot
}
if ([string]::IsNullOrWhiteSpace($CandidateScript)) {
  $CandidateScript = Join-Path $scriptRoot "dispatch-ownership.ps1"
}

function Write-Utf8([string]$Path, [string]$Content) {
  [IO.File]::WriteAllText($Path, $Content, [Text.UTF8Encoding]::new($false))
}

function New-ControlRecord(
  [string]$Runtime,
  [string]$Container,
  [int]$Number,
  [string]$TranscriptText
) {
  $launchId = [guid]::NewGuid().ToString()
  $lane = "lane-{0:d2}" -f $Number
  $worktree = Join-Path $Container $lane
  [void][IO.Directory]::CreateDirectory($worktree)
  $label = "bounded-$launchId"
  $transcript = Join-Path $Runtime "$label.jsonl"
  Write-Utf8 $transcript $TranscriptText
  $record = [pscustomobject][ordered]@{
    schemaVersion = 4
    launchId = $launchId
    laneRole = "implementation"
    promptPath = Join-Path $Runtime "dispatch-heavy-verifier-$launchId.prompt.txt"
    reviewIsolationRoot = $null
    launcherPid = 999999
    launcherStartIdentity = "2000-01-01T00:00:00.0000000Z"
    recordedAt = [DateTime]::UtcNow.ToString("o")
    state = "started"
    childPid = $PID
    childStartIdentity = (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString("o")
    worktree = $worktree
    lane = $lane
    identityMode = "branch"
    branch = "control/$lane"
    head = "a" * 40
    label = $label
    transcriptPath = $transcript
  }
  Write-DispatchOwnershipRecord (
    Join-Path $Runtime "dispatch-launch-$launchId.json"
  ) $record -CreateNew
  return $transcript
}

function Invoke-ControlReducer(
  [string]$Runtime,
  [string]$Temp,
  [string]$Container,
  [int]$DeadlineMs
) {
  return Get-LiveDispatchOwnership $Runtime $Temp $Container `
    -DeadlineMs $DeadlineMs `
    -ProcessStateResolver { param($ProcessId, $StartIdentity) "live" } `
    -GitIdentityResolver {
      param($Worktree)
      [pscustomobject]@{
        status = "ok"
        worktree = $Worktree
        branch = "control"
        head = "a" * 40
      }
    }
}

if ($ColdChild) {
  if ([string]::IsNullOrWhiteSpace($ScriptPath)) {
    throw "cold child requires -ScriptPath"
  }
  . $ScriptPath
  $childRoot = Join-Path ([IO.Path]::GetTempPath()) (
    "issue-6289-cold-child-" + [guid]::NewGuid().ToString("N")
  )
  $childRuntime = Join-Path $childRoot "runtime"
  $childTemp = Join-Path $childRoot "temp"
  $childContainer = Join-Path $childRoot "container"
  [void][IO.Directory]::CreateDirectory($childRuntime)
  [void][IO.Directory]::CreateDirectory($childTemp)
  [void][IO.Directory]::CreateDirectory($childContainer)
  try {
    foreach ($number in 1..5) {
      [void](New-ControlRecord $childRuntime $childContainer $number `
          "{`"type`":`"item.completed`"}`n")
    }
    $result = Invoke-ControlReducer $childRuntime $childTemp $childContainer 300
    [pscustomobject][ordered]@{
      candidates = [int]$result.health.counts.candidates
      examined = [int]$result.health.counts.examined
      truncated = [int]$result.health.counts.truncated
    } | ConvertTo-Json -Compress
  } finally {
    [IO.Directory]::Delete($childRoot, $true)
  }
  return
}

$repository = [IO.Path]::GetFullPath($RepositoryRoot).TrimEnd("\", "/")
$candidate = [IO.Path]::GetFullPath($CandidateScript)
$tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd("\", "/")
$root = Join-Path $tempBase (
  "issue-6289-bounded-probe-" + [guid]::NewGuid().ToString("N")
)
$variants = Join-Path $root "variants"
[void][IO.Directory]::CreateDirectory($variants)

function Set-OneReplacement(
  [string]$Source,
  [string]$Old,
  [string]$New,
  [string]$Name
) {
  $count = $Source.Split(
    [string[]]@($Old),
    [StringSplitOptions]::None
  ).Count - 1
  if ($count -ne 1) {
    throw "$Name expected one mutation point, observed $count"
  }
  return $Source.Replace($Old, $New)
}

function Get-ShellPath {
  $name = if ($PSVersionTable.PSEdition -ceq "Desktop") {
    "powershell.exe"
  } else {
    "pwsh.exe"
  }
  $path = Join-Path $PSHOME $name
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    throw "cannot locate current-edition shell: $path"
  }
  return $path
}

function Invoke-ColdRuns(
  [string]$Variant,
  [int]$Runs
) {
  $shell = Get-ShellPath
  $results = @()
  foreach ($run in 1..$Runs) {
    $output = @(& $shell -NoLogo -NoProfile -File $selfPath `
        -ColdChild -ScriptPath $Variant 2>&1)
    if ($LASTEXITCODE -ne 0) {
      throw "cold child failed for $Variant run $run`: $($output -join "`n")"
    }
    $json = @($output | Where-Object {
        ([string]$_).TrimStart().StartsWith("{")
      } | Select-Object -Last 1)
    if ($json.Count -ne 1) {
      throw "cold child returned no unique result for $Variant run $run"
    }
    $results += ($json[0] | ConvertFrom-Json)
  }
  return $results
}

function Invoke-DenseControl([string]$Variant) {
  . $Variant
  $denseRoot = Join-Path $root (
    "dense-" + [guid]::NewGuid().ToString("N")
  )
  $runtime = Join-Path $denseRoot "runtime"
  $temp = Join-Path $denseRoot "temp"
  $container = Join-Path $denseRoot "container"
  [void][IO.Directory]::CreateDirectory($runtime)
  [void][IO.Directory]::CreateDirectory($temp)
  [void][IO.Directory]::CreateDirectory($container)
  try {
    $row = '{"type":"item.completed","payload":"' + ("x" * 16) + '"}' + "`n"
    $denseText = $row * [Math]::Floor(
      1048576 / [Text.Encoding]::UTF8.GetByteCount($row)
    )
    $transcripts = @()
    foreach ($number in 1..12) {
      $transcripts += New-ControlRecord $runtime $container $number $denseText
    }
    # Isolate row-density cost from the separately governed cold initialization
    # boundary in both variants.
    [void](Get-DispatchAttemptState $transcripts[0])
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $result = Invoke-ControlReducer $runtime $temp $container 5000
    $watch.Stop()
    return [pscustomobject][ordered]@{
      elapsedMs = [long]$watch.ElapsedMilliseconds
      candidates = [int]$result.health.counts.candidates
      examined = [int]$result.health.counts.examined
      truncated = [int]$result.health.counts.truncated
    }
  } finally {
    [IO.Directory]::Delete($denseRoot, $true)
  }
}

$completed = $false
try {
  # Exact predecessor bytes from the tracked fixture (#8580), not from the
  # checkout's history.
  . (Join-Path $scriptRoot "history-fixture.ps1")
  try {
    $predecessorText = Get-HistoryFixtureText $PredecessorCommit ".orchestrator/dispatch-ownership.ps1"
  } catch {
    throw "cannot materialize exact predecessor $PredecessorCommit ($($_.Exception.Message))"
  }
  $predecessor = Join-Path $variants "predecessor.ps1"
  Write-Utf8 $predecessor $predecessorText

  $candidateSource = [IO.File]::ReadAllText($candidate)
  $delayTarget = '  if ($MaxTailBytes -le 0 -or $MaxCanonicalRowBytes -le 0) {'
  $delayReplacement = '  if (-not (Get-Variable -Name Issue6289ColdDelayConsumed -Scope Script -ErrorAction SilentlyContinue)) {
    $script:Issue6289ColdDelayConsumed = $true
    Start-Sleep -Milliseconds 350
  }
  if ($MaxTailBytes -le 0 -or $MaxCanonicalRowBytes -le 0) {'
  $slowSource = Set-OneReplacement $candidateSource $delayTarget `
    $delayReplacement "cold-delay-injection"
  $slowCandidate = Join-Path $variants "slow-candidate.ps1"
  Write-Utf8 $slowCandidate $slowSource

  $warmTarget = '$warmedAttempt = Get-DispatchAttemptState ([string]$record.transcriptPath)'
  $warmBypass = '$warmedAttempt = New-DispatchAttemptState "active" "final-row-active" 1 0 0'
  $bypassSource = Set-OneReplacement $slowSource $warmTarget $warmBypass `
    "cold-transcript-warmup-bypass"
  $coldBypass = Join-Path $variants "cold-bypass.ps1"
  Write-Utf8 $coldBypass $bypassSource

  $actualCold = @(Invoke-ColdRuns $candidate 5)
  $actualColdFailures = @($actualCold | Where-Object {
      $_.candidates -ne 5 -or $_.examined -ne 5 -or $_.truncated -ne 0
    })
  if ($actualColdFailures.Count -ne 0) {
    throw "candidate failed repeated real cold-process control"
  }

  $injectedCandidate = @(Invoke-ColdRuns $slowCandidate 3)
  $injectedCandidateFailures = @($injectedCandidate | Where-Object {
      $_.candidates -ne 5 -or $_.examined -ne 5 -or $_.truncated -ne 0
    })
  if ($injectedCandidateFailures.Count -ne 0) {
    throw "candidate meters representative transcript initialization"
  }
  $injectedBypass = @(Invoke-ColdRuns $coldBypass 1)
  if ($injectedBypass[0].examined -ge 5 -or
      $injectedBypass[0].truncated -le 0) {
    throw "cold transcript warm-up bypass did not reproduce deadline truncation"
  }

  $predecessorDense = Invoke-DenseControl $predecessor
  if ($predecessorDense.examined -ge 12 -and
      $predecessorDense.truncated -eq 0) {
    throw "exact predecessor unexpectedly cleared the dense ceiling"
  }
  $candidateDense = @(
    (Invoke-DenseControl $candidate),
    (Invoke-DenseControl $candidate),
    (Invoke-DenseControl $candidate)
  )
  $candidateDenseFailures = @($candidateDense | Where-Object {
      $_.candidates -ne 12 -or $_.examined -ne 12 -or $_.truncated -ne 0
    })
  if ($candidateDenseFailures.Count -ne 0) {
    throw "candidate failed repeated dense twelve-owner ceiling"
  }

  Write-Output (
    "F1_ACTUAL candidate=GREEN runs=5/5 examined=5/5 truncated=0"
  )
  Write-Output (
    "F1_BOUNDARY candidate=GREEN runs=3/3 bypass=RED " +
    "bypassExamined=$($injectedBypass[0].examined)/5 " +
    "bypassTruncated=$($injectedBypass[0].truncated)"
  )
  Write-Output (
    "F2_PREDECESSOR predecessor=RED elapsedMs=$($predecessorDense.elapsedMs) " +
    "examined=$($predecessorDense.examined)/12 truncated=$($predecessorDense.truncated)"
  )
  foreach ($result in $candidateDense) {
    Write-Output (
      "F2_CANDIDATE candidate=GREEN elapsedMs=$($result.elapsedMs) " +
      "examined=12/12 truncated=0"
    )
  }
  Write-Output "PASS issue-6289 bounded cold/dense probe discrimination"
  $completed = $true
} finally {
  $resolved = [IO.Path]::GetFullPath($root)
  if ((Split-Path -Parent $resolved).TrimEnd("\", "/") -ne $tempBase -or
      (Split-Path -Leaf $resolved) -notlike "issue-6289-bounded-probe-*") {
    throw "refusing unsafe bounded-probe cleanup: $resolved"
  }
  if ([IO.Directory]::Exists($resolved)) {
    [IO.Directory]::Delete($resolved, $true)
  }
}

if (-not $completed) {
  throw "bounded-probe discriminator did not complete"
}
