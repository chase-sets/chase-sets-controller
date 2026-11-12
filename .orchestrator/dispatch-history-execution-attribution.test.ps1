[CmdletBinding()]
param([string]$NativeInputPath)
$ErrorActionPreference = 'Stop'
$utf8 = [Text.UTF8Encoding]::new($false, $true)
$checks = 0
$nativeCalls = 0
function Assert-AttributionHistory([bool]$Value, [string]$Message) {
  $script:checks++
  if (-not $Value) { throw "ASSERT: $Message" }
}
function ConvertTo-AttributionJson($Value) { ConvertTo-Json -InputObject $Value -Depth 100 -Compress }
function Get-AttributionFileIdentity([string]$Path) {
  $file = Get-Item -LiteralPath $Path
  [ordered]@{ path = $file.FullName; bytes = $file.Length; mtimeUtcTicks = $file.LastWriteTimeUtc.Ticks
    sha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
}
$sourcePaths = @('dispatch-history-execution-attribution.test.ps1', 'integration-dispatch-contract.ps1',
  'landed-integration-evidence.psm1', 'dispatch-ownership.ps1', 'routing-data.ps1',
  'review-head-contract.psm1', 'dispatch-ledger-reader.psm1', 'contracts/dispatch-history-callers.json') |
  ForEach-Object { Join-Path $PSScriptRoot $_ }
function Get-AttributionInputs([string]$FixtureRoot) {
  $paths = @($sourcePaths) + @(Get-ChildItem -LiteralPath $FixtureRoot -File -Recurse |
    Sort-Object FullName | Select-Object -ExpandProperty FullName)
  ConvertTo-AttributionJson @($paths | ForEach-Object { Get-AttributionFileIdentity $_ })
}
function Get-AttributionSourceAst([string]$Path, [string]$Name) {
  $tokens = $null; $errors = $null
  $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
  Assert-AttributionHistory ($errors.Count -eq 0) "source parse: $Path"
  $functions = @($ast.FindAll({param($n)
    $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $Name
  }, $true))
  Assert-AttributionHistory ($functions.Count -eq 1) "one complete source function: $Name"
  $functions[0]
}
function Assert-AttributionLoadedSource {
  $ast = Get-AttributionSourceAst (Join-Path $PSScriptRoot 'integration-dispatch-contract.ps1') 'Get-IntegrationExecutionAttribution'
  Assert-AttributionHistory ((Get-Command Get-IntegrationExecutionAttribution).ScriptBlock.Ast.Extent.Text -ceq $ast.Extent.Text) 'complete loaded function AST equals actual source'
  $calls = @($ast.Body.FindAll({param($n)
    $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -ceq 'Read-ExactHeadReviewHistory'
  }, $true))
  Assert-AttributionHistory ($calls.Count -eq 1 -and $calls[0].Extent.Text -ceq 'Read-ExactHeadReviewHistory -Path $HistoryPath') 'literal default row16 call, no alternate limits'
  $tokens = $null; $errors = $null
  [void][Management.Automation.Language.Parser]::ParseInput($calls[0].Extent.Text, [ref]$tokens, [ref]$errors)
  $shape = @($tokens | Where-Object { $_.Kind -notin @('NewLine','LineContinuation','Comment','EndOfInput') } |
    ForEach-Object { "$($_.Kind):$($_.Text)" }) -join "`n"
  $callSha = Get-RebaseHash ($utf8.GetBytes($shape))
  $manifest = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'contracts/dispatch-history-callers.json')) | ConvertFrom-Json
  $row = $manifest.rows[15]
  Assert-AttributionHistory ($row.path -ceq '.orchestrator/integration-dispatch-contract.ps1' -and
    $row.scope -ceq 'Get-IntegrationExecutionAttribution' -and $row.api -ceq 'read-exactheadreviewhistory' -and
    $row.ordinal -eq 1 -and $row.callSha256 -ceq $callSha -and
    $callSha -ceq '56cc16f8718c6638638c02fd82428a25ef9b7f175d03be15a91bf577f91ca4fe') 'manifest index15 full caller tuple and token SHA'
  foreach ($dependency in @(
    @('Read-RebaseCompletion','landed-integration-evidence.psm1'),
    @('Read-ExactHeadReviewHistory','review-head-contract.psm1'),
    @('Read-DispatchCountHistory','dispatch-ledger-reader.psm1'))) {
    $actual = Get-AttributionSourceAst (Join-Path $PSScriptRoot $dependency[1]) $dependency[0]
    Assert-AttributionHistory ((Get-Command $dependency[0]).ScriptBlock.Ast.Extent.Text -ceq $actual.Extent.Text) "unchanged loaded dependency: $($dependency[0])"
  }
  [ordered]@{ functionSha256 = Get-RebaseHash ($utf8.GetBytes($ast.Extent.Text)); callSha256 = $callSha
    literalCall = $calls[0].Extent.Text; row = $row }
}

Import-Module (Join-Path $PSScriptRoot 'landed-integration-evidence.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'review-head-contract.psm1') -Force -DisableNameChecking
. (Join-Path $PSScriptRoot 'dispatch-ownership.ps1')
. (Join-Path $PSScriptRoot 'integration-dispatch-contract.ps1')

function Read-AttributionCohorts([string]$FixtureRoot) {
  $cohorts = Read-RebaseJson (Join-Path $FixtureRoot 'cohorts.json')
  foreach ($cohort in $cohorts) {
    $o = Read-RebaseJson $cohort.obligationPath
    # Reconstruct with the real ordinary constructor. Acceptance and spec are
    # closed observational documents, never authenticated or used to launch.
    $constructed = New-OrdinaryIntegrationObligation $o.pr $o.targetHead $o.newBase $o.branch $o.worktree $o.integrationLane
    Assert-AttributionHistory ((ConvertTo-AttributionJson $o) -ceq (ConvertTo-AttributionJson $constructed)) 'complete ordinary obligation constructor round trip'
    $spec = Read-RebaseJson $cohort.specPath
    $module = Get-Module landed-integration-evidence
    & $module { param($s)
      $keys = @($script:OrdinaryWatchdogKeys)
      [void](Add-OrdinaryRoutingKeys $s ([ref]$keys))
      Assert-RebaseKeys $s $keys
      Assert-OrdinaryStrings $s @('schemaVersion','label','attemptId','harness','model','effort','placement','laneRole',
        'originalPromptPath','partialReportPath','errorPath','worktree','branch','head','launchId','ownershipRecordPath',
        'launcherStartIdentity','childStartIdentity','state','updatedAt')
    } $spec
    $accept = Read-RebaseJson $cohort.acceptPath
    Assert-RebaseKeys $accept @('schemaVersion','obligationIdentity','ownerLaunchId','ownerRecordPath','branch','worktree','ownerPid','ownerStartIdentity','acceptedAt')
    Assert-AttributionHistory ($accept.schemaVersion -ceq 'landed-integration-owed-accept/v1' -and
      $accept.obligationIdentity -ceq (Get-RebaseObligationIdentity $o) -and $accept.ownerLaunchId -ceq $spec.launchId -and
      $accept.ownerRecordPath -ceq $spec.ownershipRecordPath -and $accept.ownerPid -eq $spec.launcherPid -and
      $accept.ownerStartIdentity -ceq $spec.launcherStartIdentity -and (Test-DispatchUtcIdentity $accept.acceptedAt) -and
      $accept.branch -ceq $o.branch -and (Test-DispatchSamePath $accept.worktree $o.worktree)) 'complete accepted ordinary observational join'
    $route = Read-RebaseJson $cohort.routePath
    Assert-RebaseKeys $route @(Get-DispatchRoutingLedgerKeys $route.dispatchRoutingSchema $route)
    Assert-AttributionHistory (Test-DispatchRoutingLedgerEvidence $route) 'real routing evidence contract'
    foreach ($key in @('head','branch','harness','model','effort','row','placement','attemptId','laneRole','label','worktree')) {
      Assert-AttributionHistory ([string]$route.$key -ceq [string]$spec.$key) "complete route/spec join: $key"
    }
    Assert-AttributionHistory ($spec.schemaVersion -ceq 'watchdog-lane/v2' -and $spec.laneRole -ceq 'implementation' -and
      $spec.relaunchCount -eq 0 -and $null -eq $spec.resumeOfLaunchId -and
      (Test-DispatchJsonInteger $spec.launcherPid 1) -and (Test-DispatchJsonInteger $spec.childPid 1) -and
      $spec.launcherPid -ne $spec.childPid -and (Test-DispatchUtcIdentity $spec.launcherStartIdentity) -and
      (Test-DispatchUtcIdentity $spec.childStartIdentity) -and (Test-DispatchUtcIdentity $spec.updatedAt) -and
      $spec.state -ceq 'exited' -and $spec.exitCode -eq 0 -and $route.kind -ceq 'dispatch' -and
      $route.lane -ceq (Split-Path -Leaf $o.worktree) -and $route.transcript -ceq "$($spec.label).jsonl" -and
      (Test-DispatchUtcIdentity $route.ts) -and [datetimeoffset]$route.ts -ge [datetimeoffset]$spec.launcherStartIdentity -and
      [datetimeoffset]$route.ts -le [datetimeoffset]$spec.childStartIdentity) 'ordinary spec and routing causal shape, no process/authority probes'
    Assert-AttributionHistory (-not (Test-Path (Join-Path $cohort.runtime "integration-rebase-complete-$($accept.obligationIdentity).json"))) 'observational acceptance path only, no completion authority'
    $cohort
  }
}
function Invoke-AttributionActual($Job, [object[]]$Cohorts, [int]$Count) {
  $before = Get-AttributionInputs $Job.fixtureRoot
  $watch = [Diagnostics.Stopwatch]::StartNew()
  $outcomes = [Collections.Generic.List[object]]::new()
  $results = [Collections.Generic.List[object]]::new()
  for ($i = 0; $i -lt $Count; $i++) {
    $c = $Cohorts[$i]; $o = Read-RebaseJson $c.obligationPath
    $start = [datetimeoffset]::UtcNow.ToString('o')
    try {
      $value = Get-IntegrationExecutionAttribution $o $c.runtime $Job.history
      $results.Add($value)
      $outcomes.Add([ordered]@{ outcome = 'returned'; startedUtc = $start; endedUtc = [datetimeoffset]::UtcNow.ToString('o')
        arguments = @($o, $c.runtime, $Job.history); result = $value; resultJson = ConvertTo-AttributionJson $value })
    } catch {
      $results.Add($null)
      $outcomes.Add([ordered]@{ outcome = 'threw'; startedUtc = $start; endedUtc = [datetimeoffset]::UtcNow.ToString('o')
        arguments = @($o, $c.runtime, $Job.history); error = $_.ToString(); scriptStackTrace = $_.ScriptStackTrace })
    }
  }
  $watch.Stop()
  $after = Get-AttributionInputs $Job.fixtureRoot
  [ordered]@{ result = $results.ToArray(); resultJson = ConvertTo-AttributionJson ($results.ToArray())
    calls = $outcomes.ToArray(); elapsedMs = $watch.Elapsed.TotalMilliseconds; inputsBefore = $before; inputsAfter = $after }
}
if ($NativeInputPath) {
  $job = Read-RebaseJson $NativeInputPath
  $binding = Assert-AttributionLoadedSource
  $cohorts = @(Read-AttributionCohorts $job.fixtureRoot)
  $first = Invoke-AttributionActual $job $cohorts $job.count
  $payload = [ordered]@{ binding = $binding; first = $first
    fixtureDocuments = @($cohorts | ForEach-Object {
      [ordered]@{ obligation = Read-RebaseJson $_.obligationPath; acceptance = Read-RebaseJson $_.acceptPath
        spec = Read-RebaseJson $_.specPath; route = Read-RebaseJson $_.routePath }
    }) }
  if ($job.mode -ceq 'append') {
    $original = [IO.File]::ReadAllBytes($job.history)
    $originalIdentity = Get-AttributionFileIdentity $job.history
    $frozen = ConvertTo-AttributionJson $first.result
    try {
      $line = [IO.File]::ReadAllText($cohorts[2].routePath).TrimEnd("`r", "`n") + "`n"
      [IO.File]::AppendAllText($job.history, $line, $utf8)
      $appended = [IO.File]::ReadAllBytes($job.history)
      $prefix = [byte[]]::new($original.Length)
      [Array]::Copy($appended, $prefix, $prefix.Length)
      $payload.appendedIdentity = Get-AttributionFileIdentity $job.history
      $payload.originalPrefixSha256 = Get-RebaseHash $prefix
      Assert-AttributionHistory ($payload.originalPrefixSha256 -ceq $originalIdentity.sha256 -and
        $appended.Length -eq $original.Length + $utf8.GetByteCount($line)) 'append preserves every original prefix byte'
      $payload.updated = Invoke-AttributionActual $job $cohorts $job.count
      $payload.replayed = Invoke-AttributionActual $job $cohorts $job.count
      $payload.frozenBefore = $frozen
      $payload.frozenAfter = ConvertTo-AttributionJson $first.result
      Assert-AttributionHistory ($frozen -ceq $payload.frozenAfter) 'earlier returned object graph stays frozen in same process'
    } finally {
      [IO.File]::WriteAllBytes($job.history, $original)
      [IO.File]::SetLastWriteTimeUtc($job.history, [datetime]::new($originalIdentity.mtimeUtcTicks, [DateTimeKind]::Utc))
    }
    $payload.restoredIdentity = Get-AttributionFileIdentity $job.history
    Assert-AttributionHistory ((ConvertTo-AttributionJson $payload.restoredIdentity) -ceq (ConvertTo-AttributionJson $originalIdentity)) 'append exact bytes/hash/length/mtime restoration'
    $payload.restored = Invoke-AttributionActual $job $cohorts $job.count
  }
  ConvertTo-AttributionJson $payload
  exit 0
}

$root = Join-Path ([IO.Path]::GetTempPath()) ('execution-attribution-history-' + [guid]::NewGuid().ToString('N'))
function Invoke-AttributionNative([string]$Name, [string]$History, [int]$Count = 2, [string]$Mode = 'read') {
  $job = [ordered]@{ fixtureRoot = $root; history = $History; count = $Count; mode = $Mode }
  $jobPath = Join-Path $root 'job.json'
  [IO.File]::WriteAllText($jobPath, (ConvertTo-AttributionJson $job), $utf8)
  $before = Get-AttributionInputs $root
  $info = [Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME $(if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' })))
  $info.UseShellExecute = $false; $info.CreateNoWindow = $true
  $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
  foreach ($arg in @('-NoProfile','-NonInteractive','-File',$PSCommandPath,'-NativeInputPath',$jobPath)) { [void]$info.ArgumentList.Add($arg) }
  $started = [datetimeoffset]::UtcNow.ToString('o'); $watch = [Diagnostics.Stopwatch]::StartNew()
  $process = [Diagnostics.Process]::Start($info)
  $stdout = $process.StandardOutput.ReadToEndAsync(); $stderr = $process.StandardError.ReadToEndAsync()
  $process.WaitForExit(); $watch.Stop()
  $out = $stdout.GetAwaiter().GetResult(); $err = $stderr.GetAwaiter().GetResult()
  $exitCode = $process.ExitCode; $process.Dispose()
  $after = Get-AttributionInputs $root
  $script:nativeCalls++
  [ordered]@{ name = $Name; executable = $info.FileName; arguments = @($info.ArgumentList); job = $job
    startedUtc = $started; endedUtc = [datetimeoffset]::UtcNow.ToString('o'); elapsedMs = $watch.Elapsed.TotalMilliseconds
    exitCode = $exitCode; inputsBefore = $before; inputsAfter = $after; stdout = $out; stderr = $err } |
    ConvertTo-Json -Depth 100 -Compress | Out-Host
  Assert-AttributionHistory ($before -ceq $after) "$Name changed source/fixture bytes, length, or mtime"
  Assert-AttributionHistory ($exitCode -eq 0 -and $err -ceq '') "$Name native child failed: exit=$exitCode stderr=$err"
  $payload = $out | ConvertFrom-Json -Depth 100 -DateKind String
  foreach ($key in @('first','updated','replayed','restored')) {
    $p = $payload.$key
    if ($null -eq $p) { continue }
    Assert-AttributionHistory ($p.inputsBefore -ceq $p.inputsAfter) "$Name/$key mutated inputs during actual caller"
    Assert-AttributionHistory ($p.calls.Count -eq $Count -and @($p.calls | Where-Object outcome -CNE 'returned').Count -eq 0) "$Name/$key actual caller threw"
  }
  $payload
}
function Assert-AttributionWhole($Actual, $Expected, [string]$Message) {
  Assert-AttributionHistory ($Actual.resultJson -ceq $Expected.resultJson) "$Message entire result differs: actual=$($Actual.resultJson) expected=$($Expected.resultJson)"
}
try {
  [void][IO.Directory]::CreateDirectory($root)
  $sourceBefore = ConvertTo-AttributionJson @($sourcePaths | ForEach-Object { Get-AttributionFileIdentity $_ })
  $binding = Assert-AttributionLoadedSource
  $cohorts = @(); $expected = @(); $routeLines = @()
  for ($i = 0; $i -lt 3; $i++) {
    $label = @('ordinary-early','ordinary-late','ordinary-appended')[$i]
    $runtime = Join-Path $root $label; $worktree = Join-Path $root "worktree-$i"
    [void][IO.Directory]::CreateDirectory($runtime); [void][IO.Directory]::CreateDirectory($worktree)
    $o = New-OrdinaryIntegrationObligation (990001 + $i) ('a' * 40) ('b' * 40) "synthetic/attribution-$i" $worktree $label
    $launch = ('00000000-0000-4000-8000-{0:d12}' -f ($i + 1))
    $ownerPath = Join-Path $runtime "dispatch-launch-$launch.json"
    $spec = [ordered]@{ schemaVersion = 'watchdog-lane/v2'; label = $label; attemptId = $label
      relaunchCount = 0; resumeOfLaunchId = $null; harness = 'codex'; model = 'synthetic-ordinary-sol'; effort = 'high'
      row = 7; placement = 'provisional'; laneRole = 'implementation'; originalPromptPath = (Join-Path $runtime "$label.prompt.txt")
      partialReportPath = (Join-Path $runtime "$label.jsonl"); errorPath = (Join-Path $runtime "$label.err.log")
      worktree = $o.worktree; branch = $o.branch; head = $o.targetHead; launchId = $launch; ownershipRecordPath = $ownerPath
      launcherPid = (800000 + 2 * $i); launcherStartIdentity = '2026-09-01T00:00:00.000Z'
      childPid = (800001 + 2 * $i); childStartIdentity = '2026-09-01T00:00:02.000Z'; state = 'exited'; exitCode = 0
      updatedAt = '2026-09-01T00:00:03.000Z'; policyGeneration = 1; registryAuthorityDigest = 'synthetic-observational'
      family = 'sol'; slot = 'codex.primary'; usedLastKnownGood = $false }
    $identity = Get-RebaseObligationIdentity $o
    $accept = [ordered]@{ schemaVersion = 'landed-integration-owed-accept/v1'; obligationIdentity = $identity
      ownerLaunchId = $launch; ownerRecordPath = $ownerPath; branch = $o.branch; worktree = $o.worktree
      ownerPid = $spec.launcherPid; ownerStartIdentity = $spec.launcherStartIdentity; acceptedAt = '2026-09-01T00:00:03.000Z' }
    $route = [ordered]@{ ts = '2026-09-01T00:00:01.000Z'; kind = 'dispatch'; dispatchRoutingSchema = 'watchdog-dispatch-routing/v2'
      attemptId = $label; label = $label; lane = (Split-Path -Leaf $worktree); laneRole = 'implementation'; transcript = "$label.jsonl"
      harness = $spec.harness; model = $spec.model; effort = $spec.effort; row = $spec.row; placement = $spec.placement
      worktree = $o.worktree; branch = $o.branch; head = $o.targetHead; policyGeneration = $spec.policyGeneration
      registryAuthorityDigest = $spec.registryAuthorityDigest; family = $spec.family; slot = $spec.slot; usedLastKnownGood = $false }
    $cohort = [ordered]@{ runtime = $runtime; obligationPath = (Join-Path $runtime 'obligation.json')
      specPath = (Join-Path $runtime "watchdog-lane-$label.json")
      acceptPath = (Join-Path $runtime "integration-owed-accept-$identity-$launch.json"); routePath = (Join-Path $runtime 'routing.json') }
    foreach ($pair in @(@($cohort.obligationPath,$o), @($cohort.specPath,$spec), @($cohort.acceptPath,$accept), @($cohort.routePath,$route))) {
      [IO.File]::WriteAllText($pair[0], (ConvertTo-AttributionJson $pair[1]), $utf8)
    }
    foreach ($path in @($spec.originalPromptPath,$spec.partialReportPath,$spec.errorPath)) { [IO.File]::WriteAllText($path, 'private observational fixture, never launched', $utf8) }
    $cohorts += $cohort
    $routeLines += (ConvertTo-AttributionJson $route) + "`n"
    # An explicit expected return, not a copied history fold. The identity is
    # computed over the saved JSON row by the production record contract, not
    # over the fixture builder's pre-serialization PowerShell values.
    $expected += [ordered]@{ launchId = $launch; harness = $spec.harness; model = $spec.model; effort = $spec.effort
      row = [long]$spec.row; placement = $spec.placement; routeIdentity = Get-RebaseRecordIdentity (Read-RebaseJson $cohort.routePath) }
  }
  [IO.File]::WriteAllText((Join-Path $root 'cohorts.json'), (ConvertTo-AttributionJson $cohorts), $utf8)
  $null = @(Read-AttributionCohorts $root)
  $small = Join-Path $root 'small-whole.jsonl'; $full = Join-Path $root 'private-full.jsonl'
  [IO.File]::WriteAllText($small, ($routeLines[0] + $routeLines[1]), $utf8)
  $writer = [IO.StreamWriter]::new($full, $false, $utf8, 65536)
  try {
    $writer.Write($routeLines[0])
    $padding = (' ' * 700) + "`n"
    for ($i = 0; $i -lt 60000; $i++) { $writer.Write($padding) }
    $writer.Write($routeLines[1])
  } finally { $writer.Dispose() }
  $original = [IO.File]::ReadAllBytes($full); $originalIdentity = Get-AttributionFileIdentity $full
  $text = $utf8.GetString($original); $lf = [regex]::Matches($text, "`n")
  $suffixStart = $lf[$lf.Count - 50000 - 1].Index + 1
  $prefixEnd = [Array]::LastIndexOf($original, [byte]10, 33554431) + 1
  $suffix = [byte[]]::new($original.Length - $suffixStart); [Array]::Copy($original, $suffixStart, $suffix, 0, $suffix.Length)
  $prefix = [byte[]]::new($prefixEnd); [Array]::Copy($original, $prefix, $prefix.Length)
  $lateOffset = $utf8.GetByteCount($routeLines[0]) + 60000 * 701
  Assert-AttributionHistory ($lf.Count -eq 60002 -and $original.Length -gt 33554432 -and $lateOffset -gt 33554432) 'sparse full input crosses both former physical cliffs'
  Assert-AttributionHistory ($suffixStart -gt $utf8.GetByteCount($routeLines[0]) -and
    ([regex]::Matches($utf8.GetString($suffix), "`n")).Count -eq 50000) 'exact original last50000 LF suffix loses only early route'
  Assert-AttributionHistory ($prefixEnd -le 33554432 -and $prefixEnd -lt $lateOffset -and
    [Array]::IndexOf($original, [byte]10, $prefixEnd) -ge 33554432) 'maximal complete-line32MiB original prefix loses only late route'
  $geometry = [ordered]@{ fullIdentity = $originalIdentity; lfLines = $lf.Count; meaningfulRows = 2; filler = '60000 whitespace-only LF lines'
    earlyOffset = 0; earlyLine = 1; lateOffset = $lateOffset; lateLine = 60002
    suffixStart = $suffixStart; suffixBytes = $suffix.Length; suffixSha256 = Get-RebaseHash $suffix
    prefixEnd = $prefixEnd; prefixBytes = $prefix.Length; prefixSha256 = Get-RebaseHash $prefix }
  ConvertTo-AttributionJson $geometry | Out-Host
  $oracle = Invoke-AttributionNative 'small-two-complete' $small
  $expectedTwoJson = ConvertTo-AttributionJson @($expected[0],$expected[1])
  ConvertTo-AttributionJson ([ordered]@{ expectedTwoJson = $expectedTwoJson; actualTwoJson = $oracle.first.resultJson }) | Out-Host
  Assert-AttributionHistory ($oracle.first.resultJson -ceq $expectedTwoJson) 'entire independent expected non-null small attribution array with exact route identities'
  $whole = Invoke-AttributionNative 'full-two-complete' $full
  Assert-AttributionWhole $whole.first $oracle.first 'whole full/small'
  $replay = Invoke-AttributionNative 'full-deterministic-replay' $full
  Assert-AttributionWhole $replay.first $whole.first 'unchanged whole replay'
  foreach ($cut in @(
    @{ name = 'suffix'; bytes = $suffix; line = $routeLines[1]; expected = @($null,$expected[1]) },
    @{ name = 'prefix'; bytes = $prefix; line = $routeLines[0]; expected = @($expected[0],$null) })) {
    $smallCut = Join-Path $root ($cut.name + '-small.jsonl')
    [IO.File]::WriteAllText($smallCut, $cut.line, $utf8)
    $cutOracle = Invoke-AttributionNative ($cut.name + '-complete-small-oracle') $smallCut
    Assert-AttributionHistory ($cutOracle.first.resultJson -ceq (ConvertTo-AttributionJson $cut.expected)) ($cut.name + ' complete retained-line whole oracle, lost-history cohort only')
    try {
      [IO.File]::WriteAllBytes($full, $cut.bytes)
      $actual = Invoke-AttributionNative ($cut.name + '-actual-original-byte-slice') $full
      Assert-AttributionWhole $actual.first $cutOracle.first ($cut.name + ' whole actual counterfactual')
      Assert-AttributionHistory ($actual.first.resultJson -cne $whole.first.resultJson) ($cut.name + ' causally differs from full')
    } finally {
      [IO.File]::WriteAllBytes($full, $original)
      [IO.File]::SetLastWriteTimeUtc($full, [datetime]::new($originalIdentity.mtimeUtcTicks, [DateTimeKind]::Utc))
    }
    Assert-AttributionHistory ((ConvertTo-AttributionJson (Get-AttributionFileIdentity $full)) -ceq (ConvertTo-AttributionJson $originalIdentity)) ($cut.name + ' exact restored bytes/hash/length/mtime')
    $restored = Invoke-AttributionNative ($cut.name + '-restored-entire-original-output') $full
    Assert-AttributionWhole $restored.first $whole.first ($cut.name + ' whole restoration replay')
  }
  # Query the same three valid cohorts on each append-control call. Before the
  # third cohort's first route exists its attribution is null, not success.
  # The primary full-history proof above requires both existing cohorts non-null.
  $updatedSmall = Join-Path $root 'appended-small-whole.jsonl'
  [IO.File]::WriteAllText($updatedSmall, ($routeLines -join ''), $utf8)
  $updatedOracle = Invoke-AttributionNative 'append-complete-small-oracle' $updatedSmall 3
  Assert-AttributionHistory ($updatedOracle.first.resultJson -ceq (ConvertTo-AttributionJson $expected)) 'entire appended small output has three non-null exact attributions'
  $appendIdentity = $null
  foreach ($pass in @('append','append-repeat')) {
    $actual = Invoke-AttributionNative ($pass + '-same-process-frozen-object') $full 3 'append'
    Assert-AttributionHistory ($actual.first.resultJson -ceq (ConvertTo-AttributionJson @($expected[0],$expected[1],$null))) 'same three-cohort preappend query, third route absent only'
    Assert-AttributionWhole $actual.updated $updatedOracle.first ($pass + ' entire updated output')
    Assert-AttributionWhole $actual.replayed $updatedOracle.first ($pass + ' deterministic appended output')
    Assert-AttributionWhole $actual.restored $actual.first ($pass + ' restored original three-cohort output')
    Assert-AttributionHistory ($actual.updated.resultJson -cne $actual.first.resultJson -and
      $actual.frozenBefore -ceq $actual.frozenAfter -and $actual.originalPrefixSha256 -ceq $originalIdentity.sha256) 'distinct first route changes whole output while returned graph and original bytes stay frozen'
    if ($null -eq $appendIdentity) { $appendIdentity = $actual.appendedIdentity } else {
      Assert-AttributionHistory ($actual.appendedIdentity.sha256 -ceq $appendIdentity.sha256 -and
        $actual.appendedIdentity.bytes -eq $appendIdentity.bytes) 'repeated append reconstructs same exact byte history'
    }
    Assert-AttributionHistory ((ConvertTo-AttributionJson (Get-AttributionFileIdentity $full)) -ceq (ConvertTo-AttributionJson $originalIdentity)) ($pass + ' parent-observed exact restoration')
    $restored = Invoke-AttributionNative ($pass + '-restored-two-cohort-whole') $full
    Assert-AttributionWhole $restored.first $whole.first ($pass + ' replay entire original two-cohort output')
  }
  Assert-AttributionHistory ($sourceBefore -ceq (ConvertTo-AttributionJson @($sourcePaths | ForEach-Object { Get-AttributionFileIdentity $_ }))) 'all existing source and new test identities unchanged during test'
  Write-Output "PASS execution attribution literal row16 checks=$checks nativeCalls=$nativeCalls LF=$($lf.Count) bytes=$($original.Length) full=two-non-null append=third-first-route; sparse observational fixtures only, NOT row15/authority/launch/rich-event/memory/all53/battery/release qualification"
} finally {
  $resolved = [IO.Path]::GetFullPath($root)
  $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')
  if ((Split-Path -Parent $resolved).TrimEnd('\','/') -cne $temp -or
    (Split-Path -Leaf $resolved) -cnotlike 'execution-attribution-history-*') { throw 'unsafe private fixture cleanup' }
  if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
