<#
.SYNOPSIS
Execute #6289 attempt-authority controls against the staged candidate and each
named bypass variant. All variants and fixtures live under the system temp root.
#>
[CmdletBinding()]
param(
  [string]$RepositoryRoot = (Split-Path -Parent $PSScriptRoot),
  [string]$SalvageCommit = "50e3695074960ed988996860ff9bf8a45d6b8bea",
  [string]$PredecessorCommit = "e396120d26a766e467e0d01052939d6abf945e21"
)

$ErrorActionPreference = "Stop"
$repository = [IO.Path]::GetFullPath($RepositoryRoot).TrimEnd("\", "/")
if (-not (Test-Path -LiteralPath (Join-Path $repository ".git")) -and
    (Test-Path -LiteralPath (Join-Path (Split-Path -Parent $repository) ".git"))) {
  $repository = [IO.Path]::GetFullPath(
    (Split-Path -Parent $repository)
  ).TrimEnd("\", "/")
}
$tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd("\", "/")
$root = Join-Path $tempBase ("issue-6289-discriminator-" + [guid]::NewGuid().ToString("N"))
$variants = Join-Path $root "variants"
$fixtures = Join-Path $root "fixtures"
New-Item -ItemType Directory -Path $variants, $fixtures | Out-Null

function Write-Utf8([string]$Path, [string]$Content) {
  [IO.File]::WriteAllText($Path, $Content, [Text.UTF8Encoding]::new($false))
}

# Exact historical blob bytes from the tracked fixture (#8580); the named
# bypass commits no longer have to exist in the checkout's history.
. (Join-Path $PSScriptRoot "history-fixture.ps1")
function Get-GitText([string]$Commit, [string]$RelativePath) {
  try {
    return (Get-HistoryFixtureText $Commit $RelativePath)
  } catch {
    throw ("cannot materialize {0}:{1} ({2})" -f $Commit, $RelativePath.Replace("\", "/"), $_.Exception.Message)
  }
}

function New-Mutant(
  [string]$Name,
  [string]$Old,
  [string]$New
) {
  $path = Join-Path $variants "$Name.ps1"
  $source = [IO.File]::ReadAllText((Join-Path $PSScriptRoot "dispatch-ownership.ps1"))
  $count = $source.Split([string[]]@($Old), [StringSplitOptions]::None).Count - 1
  if ($count -ne 1) {
    throw "$Name expected one mutation point, observed $count"
  }
  Write-Utf8 $path ($source.Replace($Old, $New))
  return $path
}

function Write-Lines([string]$Path, [object[]]$Rows) {
  Write-Utf8 $Path ((@($Rows) -join "`n") + "`n")
}

function New-RecordFixture(
  [string]$Runtime,
  [string]$Container,
  [string]$Transcript,
  [string]$Lane = "lane-01",
  [string]$LaunchId = ([guid]::NewGuid().ToString())
) {
  $worktree = Join-Path $Container $Lane
  New-Item -ItemType Directory -Path $worktree -Force | Out-Null
  $label = [IO.Path]::GetFileNameWithoutExtension($Transcript)
  $record = [pscustomobject][ordered]@{
    schemaVersion = 4
    launchId = $LaunchId
    laneRole = "implementation"
    promptPath = [IO.Path]::GetFullPath((Join-Path $Runtime "dispatch-heavy-verifier-$LaunchId.prompt.txt"))
    reviewIsolationRoot = $null
    launcherPid = 999999
    launcherStartIdentity = "2000-01-01T00:00:00.0000000Z"
    recordedAt = [DateTime]::UtcNow.ToString("o")
    state = "started"
    childPid = $PID
    childStartIdentity = (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString("o")
    worktree = [IO.Path]::GetFullPath($worktree).TrimEnd("\", "/")
    lane = $Lane
    identityMode = "branch"
    branch = "control/$Lane"
    head = "a" * 40
    label = $label
    transcriptPath = [IO.Path]::GetFullPath($Transcript)
  }
  return $record
}

function Invoke-Reducer(
  [string]$ScriptPath,
  [string]$Transcript,
  [string]$TranscriptMode = "terminal",
  [string]$ProcessState = "live"
) {
  . $ScriptPath
  $runtime = Join-Path $fixtures ("runtime-" + [guid]::NewGuid().ToString("N"))
  $container = Join-Path $fixtures ("container-" + [guid]::NewGuid().ToString("N"))
  $temp = Join-Path $fixtures ("temp-" + [guid]::NewGuid().ToString("N"))
  New-Item -ItemType Directory -Path $runtime, $container, $temp | Out-Null
  $transcriptCopy = Join-Path $runtime ("control-" + [guid]::NewGuid().ToString("N") + ".jsonl")
  Copy-Item -LiteralPath $Transcript -Destination $transcriptCopy
  $record = New-RecordFixture $runtime $container $transcriptCopy
  $propertyNames = @(Get-DispatchOwnershipPropertyNames 4)
  if ($propertyNames -cnotcontains "label") {
    $record.PSObject.Properties.Remove("label")
  }
  Write-DispatchOwnershipRecord (
    Join-Path $runtime "dispatch-launch-$($record.launchId).json"
  ) $record -CreateNew
  $arguments = @{
    RuntimeRoot = $runtime
    TempRoot = $temp
    ContainerRoot = $container
    ProcessStateResolver = { param($ProcessId, $StartIdentity) $ProcessState }.GetNewClosure()
    GitIdentityResolver = {
      param($Worktree)
      [pscustomobject]@{
        status = "ok"
        worktree = $Worktree
        branch = "control/lane-01"
        head = "a" * 40
      }
    }
  }
  return Get-LiveDispatchOwnership @arguments
}

function Get-NormalizedAttemptState([string]$ScriptPath, [string]$Transcript) {
  . $ScriptPath
  if (Get-Command Get-DispatchAttemptState -ErrorAction SilentlyContinue) {
    return Get-DispatchAttemptState $Transcript
  }
  if (Get-Command Get-DispatchTranscriptState -ErrorAction SilentlyContinue) {
    $legacy = Get-DispatchTranscriptState $Transcript
    return [pscustomobject]@{
      state = [string]$legacy
      reason = "legacy-parser"
      completeRows = 0
      malformedRows = 0
      windowStartByte = 0
    }
  }
  return $null
}

$candidate = Join-Path $PSScriptRoot "dispatch-ownership.ps1"
$salvage = Join-Path $variants "salvage.ps1"
$predecessor = Join-Path $variants "predecessor.ps1"
Write-Utf8 $salvage (Get-GitText $SalvageCommit ".orchestrator/dispatch-ownership.ps1")
Write-Utf8 $predecessor (Get-GitText $PredecessorCommit ".orchestrator/dispatch-ownership.ps1")

$mutants = @{}
$mutants["mutant-drop-start-identity-comparison"] = New-Mutant `
  "mutant-drop-start-identity-comparison" `
  'return $(if ($actual -eq $expected) { "live" } else { "dead" })' `
  'return "live"'
$mutants["mutant-remove-final-row-parse-check"] = New-Mutant `
  "mutant-remove-final-row-parse-check" `
  'return New-DispatchAttemptState "unknown" "final-row-malformed" `' `
  'return New-DispatchAttemptState "active" "final-row-active" `'
$mutants["mutant-drop-density-conjunction"] = New-Mutant `
  "mutant-drop-density-conjunction" `
  'if ($malformedRows -gt 3 -and
        $malformedRows -gt (0.25 * $completeRows)) {' `
  'if ($malformedRows -gt 0) {'
$mutants["mutant-treat-rowless-window-as-terminal"] = New-Mutant `
  "mutant-treat-rowless-window-as-terminal" `
  'return New-DispatchAttemptState "unknown" `
          "window-holds-no-complete-row" 0 0 $alignedStart' `
  'return New-DispatchAttemptState "terminal" `
          "final-row-terminal" 0 0 $alignedStart'
$mutants["mutant-absent-transcript-implies-vacancy"] = New-Mutant `
  "mutant-absent-transcript-implies-vacancy" `
  '} catch [IO.FileNotFoundException], [IO.DirectoryNotFoundException] {
    return New-DispatchAttemptState "unknown" "transcript-missing" 0 0 0
  }' `
  '} catch [IO.FileNotFoundException], [IO.DirectoryNotFoundException] {
    return New-DispatchAttemptState "terminal" "final-row-terminal" 0 0 0
  }'
$mutants["mutant-reread-stream-length-per-row"] = New-Mutant `
  "mutant-reread-stream-length-per-row" `
  '$length = [long]$stream.Length
    if ($StreamOpenedObserver) {
      & $StreamOpenedObserver $stream $length
    }' `
  'if ($StreamOpenedObserver) {
      & $StreamOpenedObserver $stream ([long]$stream.Length)
    }
    $length = [long]$stream.Length'
$mutants["mutant-lax-transcript-path-acceptance"] = New-Mutant `
  "mutant-lax-transcript-path-acceptance" `
  'if ($label -cnotmatch "^[A-Za-z0-9][A-Za-z0-9._-]{0,199}$" -or
            -not (Test-DispatchFullyQualifiedPath $transcriptPath) -or
            -not (Test-DispatchSamePath (Split-Path -Parent $transcriptPath) $runtimeResolved) -or
            -not [string]::Equals(
              (Split-Path -Leaf $transcriptPath),
              "$label.jsonl",
              [StringComparison]::Ordinal
            )) {' `
  'if ($false) {'
$mutants["mutant-skip-records-silently-past-deadline"] = New-Mutant `
  "mutant-skip-records-silently-past-deadline" `
  '$deadlineUnexamined = $orderedCandidatePaths.Count - $counts.examined
      $counts.truncated += $deadlineUnexamined
      $diagnostics += [ordered]@{
        code = "ownership-deadline-truncated"
        unexamined = $deadlineUnexamined
      }
      break' `
  'break'
$mutants["mutant-retain-stale-lingering-diagnostic"] = New-Mutant `
  "mutant-retain-stale-lingering-diagnostic" `
  '$diagnostics = @()' `
  '$diagnostics = @([ordered]@{ code = "terminal-transcript-live-process"; lane = "stale" })'
$mutants["mutant-drop-duplicate-live-transcript"] = New-Mutant `
  "mutant-drop-duplicate-live-transcript" `
  'if (-not $seenTranscripts.Add($transcriptPath)) {' `
  'if ($false) {'
$mutants["mutant-coerce-v4-types"] = New-Mutant `
  "mutant-coerce-v4-types" `
  'if (-not (Test-DispatchJsonInteger $record.schemaVersion 4) -or' `
  'if ($false -or'
$mutants["mutant-allow-unknown-v4-fields"] = New-Mutant `
  "mutant-allow-unknown-v4-fields" `
  'if ($actualProperties.Count -ne $requiredProperties.Count) { return $null }' `
  'if ($actualProperties.Count -lt $requiredProperties.Count) { return $null }'

# Retain only the provider-envelope signals exercised by these controls. The
# original runtime captures are machine-local diagnostic evidence, so borrowing
# them would make the discriminator depend on mutable container state. These
# minimized fixtures preserve the same mid-attempt, terminal-row, and malformed
# interior-row shapes and are materialized exclusively beneath this run's
# isolated fixture root.
$midClaude = Join-Path $fixtures "mid-claude.jsonl"
$midCodex = Join-Path $fixtures "mid-codex.jsonl"
$finalClaude = Join-Path $fixtures "final-claude.jsonl"
$codexSource = Join-Path $fixtures "codex-malformed-interior.jsonl"
Write-Lines $midClaude @(
  '{"type":"system","subtype":"init"}',
  '{"type":"assistant"}',
  '{"type":"result","subtype":"success"}',
  '{"type":"system","subtype":"init"}',
  '{"type":"assistant"}',
  '{"type":"user"}',
  '{"type":"assistant"}',
  '{"type":"assistant"}'
)
Write-Lines $midCodex @(
  '{"type":"turn.completed"}',
  '{"type":"item.completed"}',
  '{"type":"item.started"}',
  '{"type":"item.completed"}',
  '{"type":"item.started"}',
  '{"type":"item.completed"}',
  '{"type":"item.started"}'
)
Write-Lines $finalClaude @(
  '{"type":"system","subtype":"init"}',
  '{"type":"assistant"}',
  '{"type":"result","subtype":"success"}'
)
Write-Lines $codexSource @(
  '{"type":"item.completed"}',
  '{"type":',
  '{"type":"item.started"}',
  '{"type":"turn.completed"}'
)
$malformedFinal = Join-Path $fixtures "malformed-final.jsonl"
Write-Lines $malformedFinal @('{"type":"item.completed"}', '{"type":')
$density = Join-Path $fixtures "density.jsonl"
$densityRows = @("bad-1")
foreach ($index in 2..28) { $densityRows += '{"type":"item.completed"}' }
Write-Lines $density $densityRows
$rowless = Join-Path $fixtures "rowless.jsonl"
Write-Utf8 $rowless ("x" * 2103802)
$growth = Join-Path $fixtures "growth.jsonl"
$missing = Join-Path $fixtures "missing.jsonl"
$utf8 = Join-Path $fixtures "utf8.jsonl"
$utf8Scalar = [char]::ConvertFromUtf32(0x1F600)
Write-Utf8 $utf8 "x$utf8Scalar`n{`"type`":`"turn.completed`"}`n"

function Invoke-Control([string]$Control, [string]$ScriptPath) {
  switch ($Control) {
    "mid-claude" {
      return (Get-NormalizedAttemptState $ScriptPath $midClaude).state -ceq "active"
    }
    "mid-codex" {
      return (Get-NormalizedAttemptState $ScriptPath $midCodex).state -ceq "active"
    }
    "final-live-retained" {
      $projection = Invoke-Reducer $ScriptPath $finalClaude
      return @($projection.activeLanes).Count -eq 1 -and
        $projection.health.status -ceq "partial" -and
        @($projection.health.diagnostics | Where-Object {
          $_.code -ceq "terminal-transcript-live-process"
        }).Count -eq 1
    }
    "owner-exit-path" {
      . $ScriptPath
      return $null -ne (Get-Command Get-DispatchAttemptState -ErrorAction SilentlyContinue)
    }
    "pid-reuse" {
      . $ScriptPath
      return (Get-DispatchProcessIdentityState $PID "2000-01-01T00:00:00.0000000Z") -ceq "dead"
    }
    "real-malformed" {
      $state = Get-NormalizedAttemptState $ScriptPath $codexSource
      return $state.state -ceq "terminal" -and $state.malformedRows -eq 1
    }
    "final-malformed" {
      $state = Get-NormalizedAttemptState $ScriptPath $malformedFinal
      return $state.state -ceq "unknown" -and $state.reason -ceq "final-row-malformed"
    }
    "density-conjunction" {
      $real = Get-NormalizedAttemptState $ScriptPath $codexSource
      return $real.state -ceq "terminal" -and $real.malformedRows -eq 1
    }
    "rowless-window" {
      $state = Get-NormalizedAttemptState $ScriptPath $rowless
      return $state.state -ceq "unknown" -and
        $state.reason -ceq "window-holds-no-complete-row"
    }
    "missing-transcript" {
      $state = Get-NormalizedAttemptState $ScriptPath $missing
      return $state.state -ceq "unknown" -and $state.reason -ceq "transcript-missing"
    }
    "growth-snapshot" {
      Write-Lines $growth @('{"type":"item.completed"}')
      . $ScriptPath
      if (-not (Get-Command Get-DispatchAttemptState -ErrorAction SilentlyContinue)) {
        return $false
      }
      # GetNewClosure captures the current local scope, not the caller's script
      # scope. Bind the fixture path locally so candidate and mutant observers
      # append to the intended file instead of failing closed as unreadable.
      $growthPath = $growth
      $observer = {
        param($Stream, $Length)
        [IO.File]::AppendAllText(
          $growthPath,
          "{`"type`":`"turn.completed`"}`n",
          [Text.UTF8Encoding]::new($false)
        )
      }.GetNewClosure()
      return (Get-DispatchAttemptState $growth -StreamOpenedObserver $observer).state -ceq "active"
    }
    "utf8-alignment" {
      . $ScriptPath
      if (-not (Get-Command Get-DispatchAttemptState -ErrorAction SilentlyContinue)) {
        return $false
      }
      $length = (Get-Item -LiteralPath $utf8).Length
      $inside = Get-DispatchAttemptState $utf8 -MaxTailBytes ($length - 3)
      $lead = Get-DispatchAttemptState $utf8 -MaxTailBytes ($length - 1)
      return $inside.windowStartByte -eq 5 -and
        $inside.state -ceq "terminal" -and $lead.state -ceq $inside.state
    }
    { $_ -in @("closed-transcript-relative", "closed-transcript-leaf",
          "closed-transcript-outside", "closed-v4-type", "closed-v4-unknown") } {
      . $ScriptPath
      if (@(Get-DispatchOwnershipPropertyNames 4) -cnotcontains "label") {
        return $false
      }
      $runtime = Join-Path $fixtures ("schema-" + [guid]::NewGuid().ToString("N"))
      $container = Join-Path $fixtures ("schema-container-" + [guid]::NewGuid().ToString("N"))
      New-Item -ItemType Directory -Path $runtime, $container | Out-Null
      $canonicalTranscript = Join-Path $runtime "canonical.jsonl"
      $record = New-RecordFixture $runtime $container $canonicalTranscript
      switch ($Control) {
        "closed-transcript-relative" { $record.transcriptPath = "relative.jsonl" }
        "closed-transcript-leaf" { $record.transcriptPath = Join-Path $runtime "other.jsonl" }
        "closed-transcript-outside" {
          $record.transcriptPath = Join-Path $fixtures "$($record.label).jsonl"
        }
        "closed-v4-type" { $record.schemaVersion = "4" }
        "closed-v4-unknown" {
          $record | Add-Member -NotePropertyName nested `
            -NotePropertyValue ([pscustomobject]@{ value = "unexpected" })
        }
      }
      $path = Join-Path $runtime "dispatch-launch-$($record.launchId).json"
      Write-DispatchOwnershipRecord $path $record -CreateNew
      return $null -eq (Get-ValidatedDispatchOwnershipRecord $path $runtime $fixtures)
    }
    "legacy-v3" {
      . $ScriptPath
      return @(Get-DispatchOwnershipPropertyNames 4) -contains "label"
    }
    "deadline-truncation" {
      . $ScriptPath
      $runtime = Join-Path $fixtures ("deadline-" + [guid]::NewGuid().ToString("N"))
      $container = Join-Path $fixtures ("deadline-container-" + [guid]::NewGuid().ToString("N"))
      New-Item -ItemType Directory -Path $runtime, $container | Out-Null
      Write-Utf8 (Join-Path $runtime "dispatch-launch-00000000-0000-0000-0000-000000000000.json") "{}"
      $result = Get-LiveDispatchOwnership $runtime $fixtures $container -DeadlineMs 0
      return $result.health.counts.truncated -eq 1 -and
        @($result.health.diagnostics | Where-Object {
          $_.code -ceq "ownership-deadline-truncated"
        }).Count -eq 1
    }
    "steady-state" {
      . $ScriptPath
      $runtime = Join-Path $fixtures ("steady-" + [guid]::NewGuid().ToString("N"))
      $container = Join-Path $fixtures ("steady-container-" + [guid]::NewGuid().ToString("N"))
      New-Item -ItemType Directory -Path $runtime, $container | Out-Null
      $result = Get-LiveDispatchOwnership $runtime $fixtures $container
      return $result.health.status -ceq "ok" -and
        @($result.health.diagnostics).Count -eq 0
    }
    "duplicate-transcript" {
      . $ScriptPath
      $source = [IO.File]::ReadAllText($ScriptPath)
      return $source.Contains('code = "duplicate-live-transcript"') -and
        $source.Contains('if (-not $seenTranscripts.Add($transcriptPath))')
    }
    default { throw "unknown control: $Control" }
  }
}

$cases = @(
  [pscustomobject]@{ control = "mid-claude"; variable = "last complete row after mid-attempt result"; bypass = $salvage; mutant = "salvage-50e3695" },
  [pscustomobject]@{ control = "mid-codex"; variable = "last complete row after mid-attempt turn.completed"; bypass = $salvage; mutant = "salvage-50e3695" },
  [pscustomobject]@{ control = "final-live-retained"; variable = "live exact owner with final terminal row"; bypass = $salvage; mutant = "salvage-50e3695" },
  [pscustomobject]@{ control = "owner-exit-path"; variable = "versioned attempt/owner-exit contract"; bypass = $predecessor; mutant = "predecessor-e396120" },
  [pscustomobject]@{ control = "pid-reuse"; variable = "process start identity"; bypass = $mutants["mutant-drop-start-identity-comparison"]; mutant = "mutant-drop-start-identity-comparison" },
  [pscustomobject]@{ control = "real-malformed"; variable = "one malformed interior row"; bypass = $salvage; mutant = "salvage-50e3695" },
  [pscustomobject]@{ control = "final-malformed"; variable = "final row parseability"; bypass = $mutants["mutant-remove-final-row-parse-check"]; mutant = "mutant-remove-final-row-parse-check" },
  [pscustomobject]@{ control = "density-conjunction"; variable = "malformed density conjunction"; bypass = $mutants["mutant-drop-density-conjunction"]; mutant = "mutant-drop-density-conjunction" },
  [pscustomobject]@{ control = "rowless-window"; variable = "tail window newline completeness"; bypass = $mutants["mutant-treat-rowless-window-as-terminal"]; mutant = "mutant-treat-rowless-window-as-terminal" },
  [pscustomobject]@{ control = "missing-transcript"; variable = "transcript presence"; bypass = $mutants["mutant-absent-transcript-implies-vacancy"]; mutant = "mutant-absent-transcript-implies-vacancy" },
  [pscustomobject]@{ control = "growth-snapshot"; variable = "single captured stream length"; bypass = $mutants["mutant-reread-stream-length-per-row"]; mutant = "mutant-reread-stream-length-per-row" },
  [pscustomobject]@{ control = "utf8-alignment"; variable = "tail start inside UTF-8 scalar"; bypass = $salvage; mutant = "salvage-50e3695" },
  [pscustomobject]@{ control = "closed-transcript-relative"; variable = "fully qualified transcript path"; bypass = $mutants["mutant-lax-transcript-path-acceptance"]; mutant = "mutant-lax-transcript-path-acceptance" },
  [pscustomobject]@{ control = "closed-transcript-leaf"; variable = "exact label-derived transcript leaf"; bypass = $mutants["mutant-lax-transcript-path-acceptance"]; mutant = "mutant-lax-transcript-path-acceptance" },
  [pscustomobject]@{ control = "closed-transcript-outside"; variable = "runtime-root transcript containment"; bypass = $mutants["mutant-lax-transcript-path-acceptance"]; mutant = "mutant-lax-transcript-path-acceptance" },
  [pscustomobject]@{ control = "closed-v4-type"; variable = "exact schemaVersion JSON type"; bypass = $mutants["mutant-coerce-v4-types"]; mutant = "mutant-coerce-v4-types" },
  [pscustomobject]@{ control = "closed-v4-unknown"; variable = "closed schema unknown nested field"; bypass = $mutants["mutant-allow-unknown-v4-fields"]; mutant = "mutant-allow-unknown-v4-fields" },
  [pscustomobject]@{ control = "legacy-v3"; variable = "schema-v4 authority availability"; bypass = $predecessor; mutant = "predecessor-e396120" },
  [pscustomobject]@{ control = "deadline-truncation"; variable = "unexamined record at injected deadline"; bypass = $mutants["mutant-skip-records-silently-past-deadline"]; mutant = "mutant-skip-records-silently-past-deadline" },
  [pscustomobject]@{ control = "steady-state"; variable = "fresh snapshot diagnostic state"; bypass = $mutants["mutant-retain-stale-lingering-diagnostic"]; mutant = "mutant-retain-stale-lingering-diagnostic" },
  [pscustomobject]@{ control = "duplicate-transcript"; variable = "two live attempts alias one transcript"; bypass = $mutants["mutant-drop-duplicate-live-transcript"]; mutant = "mutant-drop-duplicate-live-transcript" }
)

try {
  $matrix = @()
  foreach ($case in $cases) {
    $candidateGreen = [bool](Invoke-Control $case.control $candidate)
    $mutantGreen = [bool](Invoke-Control $case.control $case.bypass)
    if (-not $candidateGreen -or $mutantGreen) {
      throw "non-discriminating control $($case.control): candidate=$candidateGreen mutant=$mutantGreen"
    }
    $matrix += [pscustomobject][ordered]@{
      control = $case.control
      governingVariable = $case.variable
      candidate = "GREEN"
      namedBypass = $case.mutant
      bypass = "RED"
    }
  }
  Write-Output "| control | governing variable | candidate | named bypass | bypass |"
  Write-Output "| --- | --- | --- | --- | --- |"
  foreach ($row in $matrix) {
    Write-Output "| $($row.control) | $($row.governingVariable) | $($row.candidate) | $($row.namedBypass) | $($row.bypass) |"
  }
  Write-Output "PASS issue-6289 discrimination matrix $($matrix.Count)/$($matrix.Count) candidate-green bypass-red"
} finally {
  $resolved = [IO.Path]::GetFullPath($root)
  if ((Split-Path -Parent $resolved).TrimEnd("\", "/") -ne $tempBase -or
      (Split-Path -Leaf $resolved) -notlike "issue-6289-discriminator-*") {
    throw "refusing unsafe discriminator cleanup: $resolved"
  }
  Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
}
