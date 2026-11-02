$ErrorActionPreference = "Stop"

$module = Join-Path $PSScriptRoot "lease-contract.psm1"
$cli = Join-Path $PSScriptRoot "lease.ps1"
Import-Module $module -Force -DisableNameChecking

$root = Join-Path ([IO.Path]::GetTempPath()) ("lease-contract-test-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $root | Out-Null

function Assert-True([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}

function Get-State([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return [pscustomobject]@{ exists = $false; bytes = $null; hash = $null; mtime = $null }
  }
  [pscustomobject]@{
    exists = $true
    bytes = [IO.File]::ReadAllBytes($Path)
    hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash
    mtime = [IO.File]::GetLastWriteTimeUtc($Path).Ticks
  }
}

function Assert-StateEqual([object]$Before, [object]$After, [string]$Message) {
  Assert-True ($Before.exists -eq $After.exists) "$Message (existence)"
  if (-not $Before.exists) { return }
  Assert-True ($Before.hash -ceq $After.hash) "$Message (hash)"
  Assert-True ($Before.mtime -eq $After.mtime) "$Message (mtime)"
  Assert-True ([Linq.Enumerable]::SequenceEqual([byte[]]$Before.bytes, [byte[]]$After.bytes)) "$Message (bytes)"
}

function Assert-Throws([scriptblock]$Body, [string]$Pattern, [string]$Message) {
  $caught = $null
  try { & $Body } catch { $caught = $_ }
  Assert-True ($null -ne $caught) "$Message (must throw)"
  Assert-True ("$caught" -match $Pattern) "$Message (message was '$caught')"
}

try {
  $contract = Get-OrchestrationLeaseContract
  Assert-True ($contract.version -eq "orchestration-lease/v2" -and
    $contract.sessionIdentity -eq "holder") "contract keeps the on-disk version and holder identity"
  foreach ($retired in @("freshnessMinutes", "sessionLimitHours", "legacyReadThroughUtc")) {
    Assert-True ($null -eq $contract.PSObject.Properties[$retired]) "contract removes retired field $retired"
  }

  $t0 = [datetimeoffset]"2026-07-28T15:00:00Z"
  $recordPath = Join-Path $root "lease.json"
  $missingBefore = Get-State $recordPath
  $missing = Read-OrchestrationLease -Path $recordPath -ObservedAtUtc $t0
  Assert-True ($missing.status -eq "missing" -and $null -eq $missing.record) "missing read is explicit"
  Assert-StateEqual $missingBefore (Get-State $recordPath) "missing read is non-mutating"

  Assert-Throws {
    Acquire-OrchestrationLease -Path $recordPath -Holder "codex-session-interrupted" `
      -Harness codex -Model "gpt-5.6-sol" -Effort high -NowUtc $t0 `
      -BeforeCommit { throw "injected interruption" } | Out-Null
  } "injected interruption" "interrupted initial write fails"
  Assert-True (-not (Test-Path -LiteralPath $recordPath)) "interrupted initial write publishes no record"

  $first = Acquire-OrchestrationLease -Path $recordPath -Holder "codex-session-6247-a" `
    -Harness codex -Model "gpt-5.6-sol" -Effort low -NowUtc $t0
  Assert-True ($null -eq $first.previousHolder -and $first.record.effort -ceq "low") "initial acquire reports no previous holder and accepts low effort"
  $bytes = [IO.File]::ReadAllBytes($recordPath)
  $text = [IO.File]::ReadAllText($recordPath)
  Assert-True ($bytes.Length -gt 0 -and $bytes[0] -ne 0xEF -and
    $text.EndsWith("`n") -and -not $text.Contains("`r")) "atomic record is UTF-8 without BOM and CRLF-free"

  $oldRead = Read-OrchestrationLease -Path $recordPath -ObservedAtUtc $t0.AddDays(90)
  Assert-True ($oldRead.status -ceq "ok" -and $oldRead.record.holder -ceq "codex-session-6247-a") "record age never changes validation"

  $takeover = Acquire-OrchestrationLease -Path $recordPath -Holder "claude-session-6247-b" `
    -Harness claude -Model "claude-fable-5-1" -Effort max -NowUtc $t0.AddMinutes(1)
  Assert-True ($takeover.previousHolder -ceq "codex-session-6247-a" -and
    $takeover.record.holder -ceq "claude-session-6247-b" -and
    $takeover.record.effort -ceq "max") "acquire overwrites any holder and reports the previous holder"

  $renewedSame = Renew-OrchestrationLease -Path $recordPath -Holder "claude-session-6247-b" `
    -Harness claude -Model "claude-fable-5-1" -Effort xhigh -NowUtc $t0.AddMinutes(2)
  Assert-True ($renewedSame.record.acquiredAt -ceq $takeover.record.acquiredAt -and
    $renewedSame.record.effort -ceq "xhigh" -and
    $renewedSame.previousHolder -ceq "claude-session-6247-b") "current holder renews facts while preserving acquiredAt"

  $renewedOther = Renew-OrchestrationLease -Path $recordPath -Holder "codex-session-6247-c" `
    -Harness codex -Model "gpt-6-astra" -Effort medium -NowUtc $t0.AddMinutes(3)
  Assert-True ($renewedOther.previousHolder -ceq "claude-session-6247-b" -and
    $renewedOther.record.holder -ceq "codex-session-6247-c" -and
    $renewedOther.record.acquiredAt -ceq $renewedOther.record.renewedAt) "different holder renew overwrites and starts its identity observation"

  $highPath = Join-Path $root "high.json"
  Acquire-OrchestrationLease -Path $highPath -Holder "codex-session-effort-high" `
    -Harness codex -Model "gpt-5.6-sol" -Effort high -NowUtc $t0 | Out-Null
  Assert-Throws {
    Acquire-OrchestrationLease -Path (Join-Path $root "invalid-effort.json") `
      -Holder "codex-session-effort-invalid" -Harness codex -Model "gpt-5.6-sol" `
      -Effort ultra -NowUtc $t0 | Out-Null
  } "effort-invalid" "unknown effort remains invalid"

  $malformedPath = Join-Path $root "malformed.json"
  [IO.File]::WriteAllText($malformedPath, "{not-json}", [Text.UTF8Encoding]::new($false))
  $malformedBefore = Get-State $malformedPath
  Assert-Throws {
    Acquire-OrchestrationLease -Path $malformedPath -Holder "codex-session-malformed" `
      -Harness codex -Model "gpt-5.6-sol" -Effort high -NowUtc $t0 | Out-Null
  } "status=malformed" "malformed bytes are not treated as a holder record"
  Assert-StateEqual $malformedBefore (Get-State $malformedPath) "malformed refusal changes nothing"

  $legacy = [pscustomobject][ordered]@{
    holder = "codex-session-legacy"; harness = "codex"; model = "gpt-5.6-sol"
    effort = "high"; renewedAt = "2026-07-28T14:55:00.000Z"
  }
  $legacyRead = Resolve-OrchestrationLeaseObject -Value $legacy -ObservedAtUtc $t0
  Assert-True ($legacyRead.status -ceq "malformed" -and
    @($legacyRead.diagnostics) -contains "lease-shape-invalid") "retired five-field bridge is absent"

  $racePath = Join-Path $root "race.json"
  Acquire-OrchestrationLease -Path $racePath -Holder "codex-session-race-old" `
    -Harness codex -Model "gpt-5.6-sol" -Effort high -NowUtc $t0 | Out-Null
  $intruder = '{"external":"writer"}' + "`n"
  Assert-Throws {
    Acquire-OrchestrationLease -Path $racePath -Holder "codex-session-race-new" `
      -Harness codex -Model "gpt-5.6-sol" -Effort high -NowUtc $t0.AddMinutes(1) `
      -BeforeCommit { param($Target) [IO.File]::WriteAllText($Target, $intruder, [Text.UTF8Encoding]::new($false)) } | Out-Null
  } "changed during compare-and-write" "external interleaving is detected"
  Assert-True ([IO.File]::ReadAllText($racePath) -ceq $intruder) "compare-and-write does not clobber the racing writer"

  $concurrentPath = Join-Path $root "concurrent.json"
  $pwsh = (Get-Command pwsh -CommandType Application | Select-Object -First 1).Source
  $processes = @()
  foreach ($index in 1..6) {
    $processes += Start-Process -FilePath $pwsh -WindowStyle Hidden -PassThru `
      -RedirectStandardOutput (Join-Path $root "concurrent-$index.out") `
      -RedirectStandardError (Join-Path $root "concurrent-$index.err") `
      -ArgumentList @("-NoProfile", "-NonInteractive", "-File", $cli, "-Action", "Acquire", "-Lease", $concurrentPath,
        "-Holder", "codex-concurrent-session-$index", "-Harness", "codex", "-Model", "gpt-5.6-sol", "-Effort", "high", "-NowUtc", "2026-07-28T15:00:00Z")
  }
  foreach ($process in $processes) { Assert-True ($process.WaitForExit(15000)) "concurrent writer exits" }
  Assert-True (@($processes | Where-Object ExitCode -eq 0).Count -eq 6) "file mutex serializes all identity overwrites without exclusion"
  $concurrent = Read-OrchestrationLease -Path $concurrentPath -ObservedAtUtc $t0.AddDays(30)
  Assert-True ($concurrent.status -eq "ok" -and $concurrent.record.holder -match "^codex-concurrent-session-[1-6]$") "concurrent writes leave one complete identity record"
  foreach ($process in $processes) { $process.Dispose() }

  $trialOutput = & (Join-Path $PSScriptRoot "start-host-trial.ps1") -Arm sol-high `
    -Lease $recordPath -DispatchLog (Join-Path $root "trial-log.jsonl") `
    -Holder "codex-trial-session-6247" | Out-String
  Assert-True ($trialOutput -match "host identity: holder='codex-session-6247-c'" -and
    $trialOutput -match "model='gpt-6-astra'" -and $trialOutput -match "effort='medium'" -and
    $trialOutput -match "renewedAt='2026-07-28T15:03:00.000Z'") "host trial reports an existing record's facts without refusal"
  Assert-True ($trialOutput -match "\\lease\.ps1 -Action Acquire" -and $trialOutput -match "\\lease\.ps1 -Action Renew") "host trial still prints canonical writer commands"

  $mutantPath = Join-Path $root "lease-contract-freshness-mutant.psm1"
  $source = [IO.File]::ReadAllText($module)
  $anchor = 'New-OrchestrationLeaseResult "ok" $Value @() $Fingerprint $Bytes'
  Assert-True ($source.Split([string[]]@($anchor), [StringSplitOptions]::None).Count -eq 2) "freshness mutant has one exact seam"
  $replacement = 'if (($ObservedAtUtc - $renewedAt).TotalMinutes -gt 60) { return New-OrchestrationLeaseResult "stale" $Value @("freshness-refusal") $Fingerprint $Bytes }; New-OrchestrationLeaseResult "ok" $Value @() $Fingerprint $Bytes'
  [IO.File]::WriteAllText($mutantPath, $source.Replace($anchor, $replacement), [Text.UTF8Encoding]::new($false))
  Import-Module $mutantPath -Force -Prefix FreshnessMutant -DisableNameChecking
  $mutantRead = Read-FreshnessMutantOrchestrationLease -Path $recordPath -ObservedAtUtc $t0.AddDays(90)
  Assert-True ($mutantRead.status -ceq "stale") "mutant control actually reintroduces the age refusal"
  Assert-True ($oldRead.status -ceq "ok" -and $mutantRead.status -cne $oldRead.status) "freshness-refusal mutant is red while candidate is green"

  Assert-True ((Get-Command -Module lease-contract).Name -notcontains "Handoff-CutoverRecoveryLease") "retired cutover recovery export is absent"
  Write-Output "PASS lease-contract host identity overwrite, effort, age-neutral read, atomicity, mutex, and freshness-mutant coverage"
} finally {
  if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}
