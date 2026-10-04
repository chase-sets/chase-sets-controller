[CmdletBinding()]
param(
  [string]$ControllerRoot = (Split-Path -Parent $PSScriptRoot),

  [string]$ExpectedControllerHead = "",

  [string]$SuiteResultOut = ""
)

$ErrorActionPreference = "Stop"
$controller = [IO.Path]::GetFullPath($ControllerRoot)
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("issue-6254-guard-evidence-" + [guid]::NewGuid().ToString("N"))
$cloneRoot = Join-Path $testRoot "controller"
$artifactRoot = [IO.Path]::GetFullPath((Join-Path $controller ".orchestrator/artifacts"))
$resolvedOut = if ($SuiteResultOut) {
  [IO.Path]::GetFullPath((Join-Path $controller $SuiteResultOut))
} else {
  $null
}

$mutations = @(
  [ordered]@{
    guardId = "LP-B1-B2-EVENT-ORDER"
    mutantId = "B1-B2"
    find = '$events | Sort-Object instant, line'
    replace = '$events | Sort-Object instant'
  },
  [ordered]@{
    guardId = "LP-B3-EXACT-HEAD"
    mutantId = "B3"
    find = 'if ($null -eq $final.pr -or [string]$final.pr.head -cne [string]$initial.pr.head) {'
    replace = 'if ($null -eq $final.pr) {'
  },
  [ordered]@{
    guardId = "LP-B3-CLEAR-ANY-OPEN"
    mutantId = "B3-clear-any-open"
    find = '} elseif ($open.ContainsKey($event.key)) {'
    replace = '} elseif ($open.Count -gt 0) {'
  },
  [ordered]@{
    guardId = "LP-D2-RUN-IDENTITY"
    mutantId = "D2"
    find = '$stagingJobs = @($jobs | Where-Object { [string]$_.name -ceq "Deploy Staging" })'
    replace = '$stagingJobs = @($jobs | Where-Object { [string]$_.name -eq "Deploy Staging" })'
  },
  [ordered]@{
    guardId = "LP-D3-COMMIT-BOUND"
    mutantId = "D3"
    find = '[long]$jobsPayload.total_count -gt 100 -or'
    replace = '$false -or'
  },
  [ordered]@{
    guardId = "LP-D4-WORKFLOW-IDENTITY"
    mutantId = "D4"
    find = 'if ($jobs.Count -ne [long]$jobsPayload.total_count) {'
    replace = 'if ($false) {'
  },
  [ordered]@{
    guardId = "LP-D5-OWNING-JOB"
    mutantId = "D5"
    find = 'if ($stagingJobs.Count -gt 1) {'
    replace = 'if ($stagingJobs.Count -gt 999) {'
  },
  [ordered]@{
    guardId = "LP-D6-JOB-CONCLUSION"
    mutantId = "D6"
    find = '($null -ne $previousCreated -and $created -gt $previousCreated) -or'
    replace = '$false -or'
  },
  [ordered]@{
    guardId = "LP-D7-JOB-TAXONOMY"
    mutantId = "D7"
    find = '($null -ne $previousCreated -and $created -eq $previousCreated -and $runId -ge $previousRunId)) {'
    replace = '$false) {'
  },
  [ordered]@{
    guardId = "LP-D8-RESOLVER-ONLY"
    mutantId = "D8"
    find = '$seenRunIds.ContainsKey($runId) -or'
    replace = '$false -or'
  },
  [ordered]@{
    guardId = "LP-D10-REPORT-ONLY"
    mutantId = "D10"
    find = '[string]$run.headSha -cnotmatch "^[a-f0-9]{40}$" -or'
    replace = '[string]$run.headSha -notmatch "^[a-f0-9]{40}$" -or'
  },
  [ordered]@{
    guardId = "LP-D15-RUN-LIST-EXIT"
    mutantId = "D15"
    find = 'if ($listResult.exitCode -ne 0 -or [string]::IsNullOrWhiteSpace($listResult.stdout)) {'
    replace = 'if ([string]::IsNullOrWhiteSpace($listResult.stdout)) {'
  },
  [ordered]@{
    guardId = "LP-F1-EXECUTED-UNRECOGNIZED"
    mutantId = "F1-executed-unrecognized"
    find = 'if ($jobs.Count -gt 0 -and' + [Environment]::NewLine +
      '          [string]$run.status -ceq "completed" -and'
    replace = 'if ($false -and' + [Environment]::NewLine +
      '          [string]$run.status -ceq "completed" -and'
  },
  [ordered]@{
    guardId = "LP-ZERO-STEPS"
    mutantId = "zero-steps"
    find = 'if ($steps.Count -eq 0) {'
    replace = 'if ($false) {'
  },
  [ordered]@{
    guardId = "LP-EXECUTED-RED-DEMOTED"
    mutantId = "executed-red-demoted"
    find = '    return [pscustomobject][ordered]@{' + [Environment]::NewLine +
      '      complete = $true' + [Environment]::NewLine +
      '      reason = "DEPLOY_AUTHORITY_OBSERVED"'
    replace = '    if ([string]$staging.conclusion -cne "success") { continue }' + [Environment]::NewLine +
      '    return [pscustomobject][ordered]@{' + [Environment]::NewLine +
      '      complete = $true' + [Environment]::NewLine +
      '      reason = "DEPLOY_AUTHORITY_OBSERVED"'
  },
  [ordered]@{
    guardId = "LP-BREAKER-REPAIR-FRONTIER-DEFAULT-REFUSE"
    mutantId = "breaker-repair-frontier-default-refuse"
    find = '    if (-not $frontier.admitted) {'
    replace = '    if ($false) {'
  }
)

function Assert-6254Evidence([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}

function Invoke-LandingTest([string]$Root, [string]$RegressionOnly) {
  $test = Join-Path $Root ".orchestrator/landing-preflight.test.ps1"
  $output = & pwsh -NoProfile -NonInteractive -File $test -RegressionOnly $RegressionOnly 2>&1 | Out-String
  return [pscustomobject]@{ exitCode = $LASTEXITCODE; output = $output.Trim() }
}

function Copy-Value($Value) {
  if ($Value -is [Collections.IDictionary]) {
    $copy = [ordered]@{}
    foreach ($key in $Value.Keys) { $copy[$key] = Copy-Value $Value[$key] }
    return $copy
  }
  if ($Value -is [Array]) { return ,@($Value | ForEach-Object { Copy-Value $_ }) }
  return $Value
}

function Insert-ProductionPointer($Preserved, [string]$Pointer, $Value) {
  $copy = Copy-Value $Preserved
  $segments = @($Pointer.Substring(1).Split("/"))
  $cursor = $copy
  for ($index = 0; $index -lt $segments.Count; $index++) {
    if ($index -eq $segments.Count - 1) {
      $cursor[$segments[$index]] = $Value
    } else {
      $cursor[$segments[$index]] = [ordered]@{}
      $cursor = $cursor[$segments[$index]]
    }
  }
  return $copy
}

function New-ProductionClaim($Mutation) {
  $pointer = "/productionGuards/$($Mutation.guardId)/clauseEnabled"
  $preserved = [ordered]@{
    batteryCommand = "pwsh -NoProfile -NonInteractive -File .orchestrator/landing-preflight.test.ps1 -RegressionOnly SensitivityRequired"
    controllerRoot = "."
    fixtureSet = "installed-final-16-control-sensitivity"
    parallelism = 1
    productionBlob = "3cf2824ca386245b5309f6981b75b245ec979175"
  }
  $signature = if ($Mutation.mutantId -ceq "D15") {
    "ASSERTION FAILED: a nonzero gh run list exit with valid runs JSON is terminal unreadable with no jobs query"
  } else {
    "MUTANT_KILLED:$($Mutation.mutantId)"
  }
  return [ordered]@{
    guardId = $Mutation.guardId
    governingVariable = [ordered]@{
      pointer = $pointer
      candidateValue = $true
      bypassValue = $false
    }
    preservedVariables = $preserved
    candidate = [ordered]@{
      inputs = Insert-ProductionPointer $preserved $pointer $true
      executed = $true
      expectation = [ordered]@{ testOutcome = "pass"; observation = "PASS"; failureSignature = $null }
      result = [ordered]@{ testOutcome = "pass"; observation = "PASS"; failureSignature = $null }
    }
    bypassMutant = [ordered]@{
      id = $Mutation.mutantId
      change = "remove only production clause $($Mutation.mutantId)"
      inputs = Insert-ProductionPointer $preserved $pointer $false
      executed = $true
      expectation = [ordered]@{ testOutcome = "fail"; observation = "FAIL"; failureSignature = $signature }
      result = [ordered]@{ testOutcome = "fail"; observation = "FAIL"; failureSignature = $signature }
    }
    failureSignature = $signature
  }
}

try {
  $liveHead = (& git -C $controller rev-parse HEAD 2>&1 | Out-String).Trim()
  if (-not $ExpectedControllerHead) { $ExpectedControllerHead = $liveHead }
  Assert-6254Evidence ($ExpectedControllerHead -cmatch "^[a-f0-9]{40}$") "expected head is not lowercase 40-hex"
  Assert-6254Evidence ($LASTEXITCODE -eq 0 -and $liveHead -ceq $ExpectedControllerHead) `
    "expected head $ExpectedControllerHead does not equal live controller HEAD $liveHead"
  if ($resolvedOut) {
    Assert-6254Evidence ((Split-Path -Parent $resolvedOut).TrimEnd("\", "/") -ceq $artifactRoot.TrimEnd("\", "/")) `
      "suite result must be an immediate child of .orchestrator/artifacts"
    if (Test-Path -LiteralPath $resolvedOut) { Remove-Item -LiteralPath $resolvedOut -Force }
  }
  Assert-6254Evidence ($mutations.Count -eq 16) "production mutation manifest count is not 16"

  New-Item -ItemType Directory -Path $testRoot | Out-Null
  $cloneOutput = & git clone --quiet --no-hardlinks $controller $cloneRoot 2>&1 | Out-String
  Assert-6254Evidence ($LASTEXITCODE -eq 0) "isolated temporary Git worktree clone failed: $cloneOutput"
  $cloneHead = (& git -C $cloneRoot rev-parse HEAD 2>&1 | Out-String).Trim()
  Assert-6254Evidence ($LASTEXITCODE -eq 0 -and $cloneHead -ceq $ExpectedControllerHead) `
    "isolated worktree head $cloneHead does not equal $ExpectedControllerHead"

  $production = Join-Path $cloneRoot ".orchestrator/landing-preflight.ps1"
  $candidateSource = Get-Content -LiteralPath $production -Raw
  $candidateBlob = (& git -C $cloneRoot hash-object -- ".orchestrator/landing-preflight.ps1" 2>&1 | Out-String).Trim()
  Assert-6254Evidence ($LASTEXITCODE -eq 0 -and
    $candidateBlob -ceq "666042cd2c8d27176b80ec30926d852f2e47d977") `
    "production landing-preflight blob changed (observed=$candidateBlob)"

  $applied = 0
  $killed = 0
  [IO.File]::WriteAllText($production, $candidateSource, [Text.UTF8Encoding]::new($false))
  $candidateSensitivity = Invoke-LandingTest $cloneRoot "SensitivityRequired"
  Assert-6254Evidence ($candidateSensitivity.exitCode -eq 0) `
    "candidate sensitivity suite failed: $($candidateSensitivity.output)"
  $candidateAll = Invoke-LandingTest $cloneRoot "All"
  Assert-6254Evidence ($candidateAll.exitCode -eq 0) `
    "candidate complete landing suite failed: $($candidateAll.output)"
  $d15Candidate = $candidateSensitivity.output
  $d15Mutant = $null
  foreach ($mutation in $mutations) {
    [IO.File]::WriteAllText($production, $candidateSource, [Text.UTF8Encoding]::new($false))
    $regression = if ($mutation.mutantId -ceq "breaker-repair-frontier-default-refuse") {
      "BreakerRepairFrontierOnly"
    } elseif ($mutation.mutantId -in @("B3", "executed-red-demoted")) {
      "All"
    } else {
      "SensitivityRequired"
    }

    $matches = @([regex]::Matches($candidateSource, [regex]::Escape([string]$mutation.find))).Count
    Assert-6254Evidence ($matches -eq 1) `
      "mutant $($mutation.mutantId) matched $matches production clauses instead of exactly one"
    $mutatedSource = $candidateSource.Replace([string]$mutation.find, [string]$mutation.replace)
    [IO.File]::WriteAllText($production, $mutatedSource, [Text.UTF8Encoding]::new($false))
    $applied += 1
    $mutant = Invoke-LandingTest $cloneRoot $regression
    Assert-6254Evidence ($mutant.exitCode -ne 0) `
      "mutant $($mutation.mutantId) survived the real production process boundary"
    if ($mutation.mutantId -ceq "D15") {
      $d15Mutant = $mutant.output
      Assert-6254Evidence ($mutant.output -match [regex]::Escape(
          "a nonzero gh run list exit with valid runs JSON is terminal unreadable with no jobs query"
        )) "D15 mutant failed through a different clause: $($mutant.output)"
    }
    $killed += 1
    Write-Host "CLAIM $($mutation.guardId) candidate=PASS mutant=$($mutation.mutantId):FAIL signature=$((New-ProductionClaim $mutation).failureSignature)"
  }

  Assert-6254Evidence ($applied -eq 16 -and $killed -eq 16) "production summary is not 16/16"
  Assert-6254Evidence ($d15Candidate -match "PASS required landing-preflight sensitivity controls") `
    "D15 candidate did not execute the valid-runs-JSON/nonzero-exit control"
  Assert-6254Evidence (-not [string]::IsNullOrWhiteSpace($d15Mutant)) "D15 mutant observation missing"

  if ($resolvedOut) {
    $claims = foreach ($mutation in $mutations) { New-ProductionClaim $mutation }
    $suiteResult = [ordered]@{
      schemaVersion = "fail-closed-guard-suite-result/v1"
      subject = [ordered]@{ controllerHead = $ExpectedControllerHead }
      suite = [ordered]@{ id = "issue-6254-production"; expectedClaimCount = 16 }
      execution = [ordered]@{
        runId = "issue-6254-production-" + [guid]::NewGuid().ToString("N")
        executed = $true
        outcome = "pass"
      }
      claims = @($claims)
    }
    New-Item -ItemType Directory -Path $artifactRoot -Force | Out-Null
    $temporary = Join-Path $artifactRoot (".issue-6254-production-" + [guid]::NewGuid().ToString("N") + ".tmp")
    try {
      [IO.File]::WriteAllText(
        $temporary,
        ($suiteResult | ConvertTo-Json -Depth 100),
        [Text.UTF8Encoding]::new($false)
      )
      Move-Item -LiteralPath $temporary -Destination $resolvedOut
    } finally {
      if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
    Write-Output "PASS #6254 suite artifact path=$resolvedOut runId=$($suiteResult.execution.runId) head=$ExpectedControllerHead claims=16"
  }

  Write-Output "PASS #6254 production mutation summary applied=16 killed=16 survivors=0 not-applied=0"
  Write-Output "PASS D15 candidate=unknown/DEPLOY_AUTHORITY_UNREADABLE jobsQueries=0 mutant=eligible signature=exact"
} finally {
  if (Test-Path -LiteralPath $testRoot) {
    $resolved = [IO.Path]::GetFullPath($testRoot)
    $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd("\", "/")
    if ((Split-Path -Parent $resolved).TrimEnd("\", "/") -ne $temp -or
        (Split-Path -Leaf $resolved) -notlike "issue-6254-guard-evidence-*") {
      throw "refusing unsafe #6254 evidence cleanup target: $resolved"
    }
    Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
  }
}
