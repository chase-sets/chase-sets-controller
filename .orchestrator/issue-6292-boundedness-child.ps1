[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$VariantPath,
  [string]$MutantTypeName,
  [string]$FixtureRoot
)

$ErrorActionPreference = "Stop"
$tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd("\", "/")
$ownsFixture = [string]::IsNullOrWhiteSpace($FixtureRoot)
$root = if ($ownsFixture) {
  [IO.Path]::Combine(
    $tempBase,
    "issue-6292-boundedness-child-" + [guid]::NewGuid().ToString("N")
  )
} else {
  [IO.Path]::GetFullPath($FixtureRoot)
}
$runtime = [IO.Path]::Combine($root, "runtime")
$providerTemp = [IO.Path]::Combine($root, "provider-temp")
$container = [IO.Path]::Combine($root, "container")
if ($ownsFixture) {
  [void][IO.Directory]::CreateDirectory($runtime)
  [void][IO.Directory]::CreateDirectory($providerTemp)
  [void][IO.Directory]::CreateDirectory($container)
}

function Write-Utf8([string]$Path, [string]$Content) {
  [IO.File]::WriteAllText($Path, $Content, [Text.UTF8Encoding]::new($false))
}

function New-InstantRecord([int]$Number) {
  $lane = "lane-{0:d2}" -f $Number
  $worktree = [IO.Path]::Combine($container, $lane)
  [void][IO.Directory]::CreateDirectory($worktree)
  $launchId = "00000000-0000-0000-0000-{0:d12}" -f $Number
  $promptPath = [IO.Path]::Combine(
    $runtime,
    "dispatch-heavy-verifier-$launchId.prompt.txt"
  )
  $escape = {
    param([string]$Value)
    $Value.Replace("\", "\\").Replace('"', '\"')
  }
  $json = (
    '{"schemaVersion":3,"launchId":"' + $launchId +
    '","laneRole":"implementation","promptPath":"' + (& $escape $promptPath) +
    '","reviewIsolationRoot":null,"launcherPid":999999,' +
    '"launcherStartIdentity":"2000-01-01T00:00:00.0000000Z",' +
    '"recordedAt":"2000-01-01T00:00:00.0000000Z","state":"started",' +
    '"childPid":999998,"childStartIdentity":"2000-01-01T00:00:00.0000000Z",' +
    '"worktree":"' + (& $escape $worktree) + '","lane":"' + $lane +
    '","identityMode":"branch","branch":"recorded/branch","head":"' +
    ("a" * 40) + '"}'
  )
  Write-Utf8 (
    [IO.Path]::Combine($runtime, "dispatch-launch-$launchId.json")
  ) $json
}

try {
  if ($ownsFixture) {
    foreach ($number in 1..5) { New-InstantRecord $number }
  }
  . ([IO.Path]::Combine(
      [IO.Path]::GetFullPath($VariantPath),
      "dispatch-ownership.ps1"
    ))
  $processResolver = { param($ProcessId, $StartIdentity) "live" }
  $gitResolver = {
    param($Worktree)
    [pscustomobject]@{
      status = "ok"
      worktree = $Worktree
      branch = "recorded/branch"
      head = "a" * 40
    }
  }
  $typeAbsentBefore = if ($MutantTypeName) {
    $null -eq ($MutantTypeName -as [type])
  } else {
    $null
  }
  $firstWatch = [Diagnostics.Stopwatch]::StartNew()
  $first = Get-LiveDispatchOwnership $runtime $providerTemp $container `
    -DeadlineMs 300 -ProcessStateResolver $processResolver `
    -GitIdentityResolver $gitResolver
  $firstWatch.Stop()
  $typePresentAfter = if ($MutantTypeName) {
    $null -ne ($MutantTypeName -as [type])
  } else {
    $null
  }
  $secondWatch = [Diagnostics.Stopwatch]::StartNew()
  $second = Get-LiveDispatchOwnership $runtime $providerTemp $container `
    -DeadlineMs 300 -ProcessStateResolver $processResolver `
    -GitIdentityResolver $gitResolver
  $secondWatch.Stop()
  [pscustomobject][ordered]@{
    schema = "issue-6292-boundedness-child/v1"
    processId = $PID
    coldFirst = [ordered]@{
      invocationPosition = "cold-first-call-fresh-pwsh"
      candidates = $first.health.counts.candidates
      examined = $first.health.counts.examined
      truncated = $first.health.counts.truncated
      elapsedMs = [math]::Round($firstWatch.Elapsed.TotalMilliseconds, 1)
      diagnosticCodes = @($first.health.diagnostics | ForEach-Object { $_.code })
      mutantTypeAbsentBefore = $typeAbsentBefore
      mutantTypePresentAfter = $typePresentAfter
    }
    warmSecond = [ordered]@{
      invocationPosition = "warm-second-call-same-pwsh"
      candidates = $second.health.counts.candidates
      examined = $second.health.counts.examined
      truncated = $second.health.counts.truncated
      elapsedMs = [math]::Round($secondWatch.Elapsed.TotalMilliseconds, 1)
      diagnosticCodes = @($second.health.diagnostics | ForEach-Object { $_.code })
    }
  } | ConvertTo-Json -Compress -Depth 6
} finally {
  if ($ownsFixture) {
    $resolved = [IO.Path]::GetFullPath($root)
    if (-not $resolved.StartsWith(
        $tempBase + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase
      ) -or
        (Split-Path -Leaf $resolved) -notlike "issue-6292-boundedness-child-*") {
      throw "refusing unsafe boundedness cleanup target: $resolved"
    }
    Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
  }
}
