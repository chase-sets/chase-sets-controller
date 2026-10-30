[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$guard = Join-Path $PSScriptRoot 'invoke-heavy-verifier.ps1'
function Assert-True($Condition, [string]$Message) { if (-not $Condition) { throw "ASSERTION FAILED: $Message" } }
function Start-TestChild([string[]]$Arguments, [hashtable]$Environment = @{}) {
  $start = [Diagnostics.ProcessStartInfo]::new()
  $start.FileName = Join-Path $PSHOME 'pwsh.exe'; $start.UseShellExecute = $false; $start.CreateNoWindow = $true
  $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
  foreach ($argument in $Arguments) { [void]$start.ArgumentList.Add([string]$argument) }
  foreach ($entry in $Environment.GetEnumerator()) { $start.Environment[$entry.Key] = [string]$entry.Value }
  $process = [Diagnostics.Process]::Start($start)
  [void]$process.Handle
  return [pscustomobject]@{ Process = $process; StartTicks=$process.StartTime.ToUniversalTime().Ticks; Stdout = $process.StandardOutput.ReadToEndAsync(); Stderr = $process.StandardError.ReadToEndAsync() }
}
function Complete-TestChild($Started) {
  $Started.Process.WaitForExit()
  return [pscustomobject]@{ Code = $Started.Process.ExitCode; Stdout = $Started.Stdout.GetAwaiter().GetResult(); Stderr = $Started.Stderr.GetAwaiter().GetResult() }
}
function Invoke-Child([string[]]$Arguments, [hashtable]$Environment = @{}) {
  return Complete-TestChild (Start-TestChild $Arguments $Environment)
}

$root = Join-Path ([IO.Path]::GetFullPath([IO.Path]::GetTempPath())) ('diagnostic-admission-' + [guid]::NewGuid().ToString('N'))
$container = Join-Path $root 'container'; $worktree = Join-Path $container 'lane'; $runtime = Join-Path $container '.orchestrator'
$artifactRoot = Join-Path $worktree '.orchestrator\artifacts'; $declarationPath = Join-Path $runtime 'diagnostic-declarations.json'; $lockRoot = Join-Path $runtime 'verify-lock.d'
New-Item -ItemType Directory -Path $worktree, $runtime, $artifactRoot -Force | Out-Null
$releaseDeclarations = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'diagnostic-declarations.json') -Raw | ConvertFrom-Json
$chromiumDeclaration = $releaseDeclarations.diagnostics.'staged-import-chromium-control'
Assert-True ($releaseDeclarations.schema -ceq 'host-heavy-diagnostic-declarations/v1' -and
  $chromiumDeclaration.enabled -eq $true -and $chromiumDeclaration.kind -ceq 'standalone-node' -and
  $chromiumDeclaration.path -ceq '.tmp/operator-7334-staged-import/chromium-control.mjs' -and
  $chromiumDeclaration.sha256 -ceq '1ba41595d8045fb377ca97a3b059e5679257ef5d0b60470e4be610aece91aa7d' -and
  $chromiumDeclaration.maxBudgetSeconds -eq 900) 'release declaration pins staged-import Chromium path, bytes and 900-second cap'
Write-Output 'PASS release declaration staged-import-chromium-control path=1 sha256=1 maxBudget=900'
$censusDeclaration = $releaseDeclarations.diagnostics.'json-census-five-run'
$censusReviewedSha256 = '1bdd1c7539e89c4925402f502956ce6aa7334c18338ac950b190a56e92e647ce'
Assert-True ((@($releaseDeclarations.diagnostics.PSObject.Properties.Name) -join ',') -ceq 'worst13-no-fit,staged-import-chromium-control,json-census-five-run,canonical-vitest-residual-v1' -and
  $censusDeclaration.enabled -eq $true -and $censusDeclaration.kind -ceq 'standalone-node' -and
  $censusDeclaration.path -ceq '.tmp/10761-json-census/census-runner.mjs' -and
  $censusDeclaration.sha256 -ceq $censusReviewedSha256 -and $censusDeclaration.maxBudgetSeconds -eq 600 -and
  $censusDeclaration.PSObject.Properties.Name -cnotcontains 'dependencies') 'release declaration adds only json-census-five-run with its ignored path, reviewed bytes and 600-second cap'
Write-Output 'PASS release declaration json-census-five-run names=3 path=1 sha256=1 maxBudget=600 dependencies=0'
# The controller publishes the reviewed runner; the lane copies it unchanged to the declared seat path.
$censusRunnerSource = Join-Path $PSScriptRoot 'diagnostics/10761-json-census-runner.mjs'
Assert-True ((Test-Path -LiteralPath $censusRunnerSource -PathType Leaf) -and
  [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([IO.File]::ReadAllBytes($censusRunnerSource))).ToLowerInvariant() -ceq $censusDeclaration.sha256) 'committed diagnostics/10761-json-census-runner.mjs hashes to the declared json-census-five-run sha256'
Write-Output 'PASS release declaration json-census-five-run committed-runner sha256=declared'
$canonicalDeclaration = $releaseDeclarations.diagnostics.'canonical-vitest-residual-v1'
$canonicalArguments = @('exec','vitest','run','--config','./vitest.scripts.config.mjs','scripts/canonical-record.test.mjs','--maxWorkers=1','--fileParallelism=false','--silent=false')
Assert-True ($canonicalDeclaration.enabled -eq $true -and $canonicalDeclaration.kind -ceq 'vitest-command' -and
  $canonicalDeclaration.path -ceq 'scripts/canonical-record.test.mjs' -and
  $canonicalDeclaration.command.executable -ceq 'pnpm' -and
  ((@($canonicalDeclaration.command.arguments) -join "`n") -ceq ($canonicalArguments -join "`n")) -and
  $canonicalDeclaration.maxBudgetSeconds -eq 600 -and
  $canonicalDeclaration.PSObject.Properties.Name -notcontains 'sha256') 'release declaration pins the exact canonical Vitest command, tracked entry and 600-second cap without a wrapper hash'
Write-Output 'PASS release declaration canonical-vitest-residual-v1 kind=vitest-command exact-argv=1 path=1 maxBudget=600 wrapper=0'
function Invoke-FixtureGit([string[]]$Arguments) {
  $output = @(& git -C $worktree @Arguments 2>&1); if ($LASTEXITCODE -ne 0) { throw "fixture git failed: $($output -join "`n")" }; return ($output -join "`n").Trim()
}
function Get-Sha256([string]$Path) { return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([IO.File]::ReadAllBytes($Path))).ToLowerInvariant() }
function Write-Declaration([string]$RelativePath, [string]$Hash, [double]$Maximum = 4, [bool]$Enabled = $true, [object[]]$Dependencies = $null) {
  $definition=@{ enabled=$Enabled; kind='standalone-node'; path=$RelativePath; sha256=$Hash; maxBudgetSeconds=$Maximum }
  if ($null -ne $Dependencies) { $definition.dependencies = @($Dependencies) }
  [IO.File]::WriteAllText($declarationPath, (@{ schema='host-heavy-diagnostic-declarations/v1'; diagnostics=@{ 'worst13-no-fit'=$definition; 'staged-import-chromium-control'=$definition } } | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
}
function New-DiagnosticClockFixture {
  param([DateTimeOffset]$Now = [DateTimeOffset]::UtcNow)
  $path = Join-Path $root ('diagnostic-clock-' + [guid]::NewGuid().ToString('N') + '.json')
  [IO.File]::WriteAllText($path, (@{ schema='test-diagnostic-clock/v1'; now=$Now.ToString('o') } | ConvertTo-Json -Depth 4), [Text.UTF8Encoding]::new($false))
  return $path
}
function Set-DiagnosticClock([string]$Path, [DateTimeOffset]$Now) {
  $destination = if (Test-Path -LiteralPath $Path) { "$Path.advanced" } else { $Path }
  $pending = "$destination.pending"
  [IO.File]::WriteAllText($pending, (@{ schema='test-diagnostic-clock/v1'; now=$Now.ToString('o') } | ConvertTo-Json -Depth 4), [Text.UTF8Encoding]::new($false))
  [IO.File]::Move($pending, $destination)
}
function New-TestOnlyDiagnosticGuard {
  param([string]$Name = 'test-orchestrator', [switch]$DisableTimeout)
  $testOrchestrator = Join-Path $root $Name
  New-Item -ItemType Directory -Path $testOrchestrator -Force | Out-Null
  foreach ($name in @('dispatch-ownership.ps1','heavy-admission-preload.cjs','heavy-slot.cjs','heavy-nested-owner.cs','heavy-nested-client.cjs','workspace-db-test.mjs','native-db-admission.py','heavy-admission-holder-launcher.cjs')) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination (Join-Path $testOrchestrator $name) -Force
  }
  $clockFunction = @'
function Get-TestDiagnosticNow {
  $clockPath = $env:DIAGNOSTIC_CLOCK_FIXTURE
  if (Test-Path -LiteralPath "$clockPath.advanced") {
    $clockPath = "$clockPath.advanced"
    $script:testExpiredClockReads++
    [IO.File]::WriteAllText("$($env:DIAGNOSTIC_CLOCK_OBSERVED).$script:testExpiredClockReads", 'past-budget')
  }
  $fixture = [IO.File]::ReadAllText($clockPath) | ConvertFrom-Json -ErrorAction Stop
  return ([DateTimeOffset]::Parse([string]$fixture.now)).UtcDateTime
}
'@
  $testText = [IO.File]::ReadAllText($guard)
  $testText = $testText.Replace('$ErrorActionPreference = "Stop"', $clockFunction + [Environment]::NewLine + '$ErrorActionPreference = "Stop"')
  $clockRead = '$remaining = [int][Math]::Floor(($deadline - [DateTime]::UtcNow).TotalMilliseconds)'
  $clockReadCount = ([regex]::Matches($testText, [regex]::Escape($clockRead))).Count
  Assert-True ($clockReadCount -eq 1) "fixture verifier timeout clock substitution matched exactly once (count=$clockReadCount)"
  $testText = $testText.Replace($clockRead, '$remaining = [int][Math]::Floor(($deadline - (Get-TestDiagnosticNow)).TotalMilliseconds)')
  $script:diagnosticClockSubstitutionCount = $clockReadCount
  if ($DisableTimeout) {
    $timeoutBranch = 'if ($remaining -le 0) {'
    $timeoutBranchCount = ([regex]::Matches($testText, [regex]::Escape($timeoutBranch))).Count
    Assert-True ($timeoutBranchCount -eq 1) "named timeout mutant target matched exactly once (count=$timeoutBranchCount)"
    # Keep WaitForExit's argument valid while disabling only the expired-budget branch.
    $testText = $testText.Replace($timeoutBranch, '$remaining = [Math]::Max(100, $remaining); if ($false) {')
  }
  $path = Join-Path $testOrchestrator 'invoke-heavy-verifier.ps1'
  Copy-Item -LiteralPath $guard -Destination $path -Force
  [IO.File]::WriteAllText($path, $testText, [Text.UTF8Encoding]::new($false))
  return $path
}
function Assert-NoProductionDiagnosticClockSeam {
  $matches = @(& git -C (Split-Path -Parent $PSScriptRoot) grep -n -E 'TestDiagnosticClockFixture|DIAGNOSTIC_CLOCK_FIXTURE|Get-DiagnosticNow' -- '.orchestrator/invoke-heavy-verifier.ps1' 2>$null)
  $exitCode = $LASTEXITCODE
  Assert-True ($exitCode -eq 1 -and $matches.Count -eq 0) "production verifier exposes a diagnostic clock seam (git grep exit=$exitCode matches=$($matches -join '; '))"
  Write-Output 'PASS production verifier diagnostic-clock-seam=absent git-grep=1'
}
function Assert-MutantDiagnosticClockSeamIsRejected {
  $production = Join-Path $PSScriptRoot 'invoke-heavy-verifier.ps1'
  $mutantRelative = '.orchestrator/.diagnostic-admission-mutant-' + [guid]::NewGuid().ToString('N') + '.ps1'
  $mutant = Join-Path (Split-Path -Parent $PSScriptRoot) ($mutantRelative -replace '/', '\')
  $parameter = '[Parameter(DontShow)][string]$TestDiagnosticClockFixture,'
  $anchor = '[Parameter(DontShow)][ValidateRange(0, 30000)][int]$TestDelayDiagnosticLaunchMilliseconds,'
  $replacement = $anchor + [Environment]::NewLine + '  ' + $parameter
  try {
    $mutantText = [IO.File]::ReadAllText($production).Replace($anchor, $replacement)
    [IO.File]::WriteAllText($mutant, $mutantText, [Text.UTF8Encoding]::new($false))
    $matches = @(& git -C (Split-Path -Parent $PSScriptRoot) grep --no-index -n -E 'TestDiagnosticClockFixture|DIAGNOSTIC_CLOCK_FIXTURE|Get-DiagnosticNow' -- $mutantRelative 2>$null)
    Assert-True ($LASTEXITCODE -eq 0 -and $matches.Count -gt 0) 'mutant re-added the diagnostic clock seam'
    $failed = $false
    try {
      Assert-True ($matches.Count -eq 0) "production verifier exposes a diagnostic clock seam (mutant matches=$($matches -join '; '))"
    } catch {
      $failed = $true
      Write-Output 'KILLED mutant production-diagnostic-clock-parameter'
    }
    Assert-True $failed 'mutant that re-adds the diagnostic clock parameter must turn the guard red'
  } finally {
    if (Test-Path -LiteralPath $mutant) { Remove-Item -LiteralPath $mutant -Force -ErrorAction SilentlyContinue }
  }
}
function Invoke-Diagnostic([hashtable]$Overrides = @{}, [string]$MarkerName = 'marker', [hashtable]$ChildEnvironment = @{}, [string]$DiagnosticName = 'worst13-no-fit', [string]$GuardPath = '') {
  $parameters = [ordered]@{ '-Diagnostic'=$DiagnosticName; '-DiagnosticScriptPath'=$scriptRelative; '-DiagnosticSha256'=$scriptHash; '-DiagnosticBudgetSeconds'='2'; '-Worktree'=$worktree; '-Lane'='lane-test'; '-Branch'='codex/test'; '-ClaimedHead'=$head; '-ContainerRoot'=$container }
  foreach ($entry in $Overrides.GetEnumerator()) { if ($null -eq $entry.Value) { [void]$parameters.Remove($entry.Key) } else { $parameters[$entry.Key]=$entry.Value } }
  $entryGuard=if ($GuardPath) { $GuardPath } else { $testGuard }
  $args=@('-NoProfile','-NonInteractive','-File',$entryGuard); foreach ($entry in $parameters.GetEnumerator()) { $args += @($entry.Key,[string]$entry.Value) }
  $marker=Join-Path $root "$MarkerName.marker"; $clockPath=New-DiagnosticClockFixture; $environment=@{ DIAGNOSTIC_MARKER=$marker; DIAGNOSTIC_PID=(Join-Path $root "$MarkerName.pid"); DIAGNOSTIC_CLOCK_FIXTURE=$clockPath }; foreach($entry in $ChildEnvironment.GetEnumerator()) { $environment[$entry.Key]=$entry.Value }; $result=Invoke-Child $args $environment
  return [pscustomobject]@{ Result=$result; Marker=$marker; PidPath=(Join-Path $root "$MarkerName.pid") }
}
function New-BarrierDiagnostic([string]$GuardPath, [string]$Name, [switch]$LingeringDescendant, [hashtable]$ChildEnvironment = @{}) {
  $clockPath=Join-Path $root "$Name.clock.json"; Set-DiagnosticClock $clockPath ([DateTimeOffset]::UtcNow)
  $barrier=Join-Path $root "$Name.barrier"; $release=Join-Path $root "$Name.release"; $pidPath=Join-Path $root "$Name.pid"; $rootPidPath=Join-Path $root "$Name.root.pid"; $rootRelease=Join-Path $root "$Name.root.release"; $observed=Join-Path $root "$Name.clock-observed"
  $parameters=[ordered]@{ '-Diagnostic'='staged-import-chromium-control'; '-DiagnosticScriptPath'=$scriptRelative; '-DiagnosticSha256'=$scriptHash; '-DiagnosticBudgetSeconds'='900'; '-Worktree'=$worktree; '-Lane'='lane-test'; '-Branch'='codex/test'; '-ClaimedHead'=$head; '-ContainerRoot'=$container }
  $args=@('-NoProfile','-NonInteractive','-File',$GuardPath); foreach ($entry in $parameters.GetEnumerator()) { $args += @($entry.Key,[string]$entry.Value) }
  $environment=@{ DIAGNOSTIC_CLOCK_FIXTURE=$clockPath; DIAGNOSTIC_CLOCK_OBSERVED=$observed; DIAGNOSTIC_BARRIER=$barrier; DIAGNOSTIC_RELEASE=$release; DIAGNOSTIC_CHILD_PID=$pidPath; DIAGNOSTIC_ROOT_PID=$rootPidPath; DIAGNOSTIC_ROOT_RELEASE=$rootRelease; DIAGNOSTIC_LINGERING_DESCENDANT=[string][int][bool]$LingeringDescendant }
  foreach ($entry in $ChildEnvironment.GetEnumerator()) { $environment[$entry.Key]=$entry.Value }
  $receiptsBefore=@(Get-ChildItem -LiteralPath $artifactRoot -Filter 'host-heavy-diagnostic-*.json' -File | ForEach-Object FullName)
  return [pscustomobject]@{ Started=(Start-TestChild $args $environment); Clock=$clockPath; Observed=$observed; Barrier=$barrier; Release=$release; PidPath=$pidPath; RootPidPath=$rootPidPath; RootRelease=$rootRelease; ReceiptsBefore=$receiptsBefore; Processes=[Collections.Generic.List[Diagnostics.Process]]::new() }
}
function Wait-BarrierDiagnostic($Run) {
  $watch=[Diagnostics.Stopwatch]::StartNew()
  while ($watch.ElapsedMilliseconds -lt 60000) {
    if ($Run.Started.Process.HasExited) {
      $result=Complete-TestChild $Run.Started
      Assert-True $false "barrier-child-ready: verifier exited before a live barrier child (exit=$($result.Code) pidFile=$(Test-Path -LiteralPath $Run.PidPath) stderr=$($result.Stderr))"
    }
    if ((Test-Path -LiteralPath $Run.PidPath) -and (Test-Path -LiteralPath $Run.Barrier)) {
      $childPid=[int]([IO.File]::ReadAllText($Run.PidPath))
      $child=Get-Process -Id $childPid -ErrorAction Stop
      [void]$child.Handle
      $Run.Processes.Add($child)
      Assert-True (-not $child.HasExited -and -not (Test-Path -LiteralPath $Run.Release)) "barrier-child-ready: live native child holds unreleased barrier (pid=$childPid)"
      Write-Output "PASS barrier-child-ready pid=$childPid live=1 barrier-held=1"
      return
    }
    Start-Sleep -Milliseconds 25
  }
  Assert-True $false 'barrier-child-ready: native PID and barrier files must appear before clock advance'
}
function Wait-DiagnosticBudgetOutcome($Run) {
  $watch=[Diagnostics.Stopwatch]::StartNew()
  # A second expired-clock read proves a complete verifier iteration survived the budget.
  while (-not $Run.Started.Process.HasExited -and -not (Test-Path -LiteralPath "$($Run.Observed).2") -and $watch.ElapsedMilliseconds -lt 15000) { Start-Sleep -Milliseconds 25 }
  $completed=$Run.Started.Process.HasExited
  $result=if ($completed) { Complete-TestChild $Run.Started } else { $null }
  Assert-True (-not $completed -or $result.Code -ne 73) "timeout-route-setup: admission must not refuse (exit=$(if($result){$result.Code}else{'running'}) stderr=$(if($result){$result.Stderr}else{'<running>'}))"
  return [pscustomobject]@{ Completed=$completed; Result=$result; SurvivedBudget=(Test-Path -LiteralPath "$($Run.Observed).2") }
}
function Assert-DiagnosticTimeoutExit($Outcome, [string]$Name) {
  Assert-True ($Outcome.Completed -and $Outcome.Result.Code -eq 124) "$Name`: real diagnostic route must exit 124 after budget (exit=$(if($Outcome.Result){$Outcome.Result.Code}else{'running'}) stderr=$(if($Outcome.Result){$Outcome.Result.Stderr}else{'<running>'}))"
}
function Close-BarrierDiagnostic($Run) {
  New-Item -ItemType File -Path $Run.Release, $Run.RootRelease -Force | Out-Null
  if (-not $Run.Started.Process.WaitForExit(5000)) { Stop-TestExactProcess $Run.Started.Process $Run.Started.StartTicks }
  foreach ($process in $Run.Processes) {
    if (-not $process.HasExited) { Stop-TestExactProcess $process $process.StartTime.ToUniversalTime().Ticks }
  }
}
function Stop-TestExactProcess($Owned, [long]$StartTicks) {
  $live=$null
  try {
    $live=Get-Process -Id $Owned.Id -ErrorAction Stop
    [void]$live.Handle
    if ($live.StartTime.ToUniversalTime().Ticks -eq $StartTicks -and -not $live.HasExited) { $live.Kill(); [void]$live.WaitForExit(5000) }
  } catch {} finally { if ($live) { $live.Dispose() } }
}
function Assert-Refused([object]$Case, [string]$ExpectedText) {
  Assert-True ($Case.Result.Code -eq 73) "refused with documented code (actual=$($Case.Result.Code) stderr=$($Case.Result.Stderr))"
  Assert-True ($Case.Result.Stderr -match [regex]::Escape("heavy-verifier: $ExpectedText")) "exact refusal text '$ExpectedText' (stderr=$($Case.Result.Stderr))"
  Assert-True (-not (Test-Path -LiteralPath $Case.Marker)) 'fresh marker proves the diagnostic did not run'
  Assert-True (-not (Test-Path -LiteralPath $lockRoot)) 'refusal released no-acquisition lock'
}
function Get-DiagnosticReceiptPaths {
  return @(Get-ChildItem -LiteralPath $artifactRoot -Filter 'host-heavy-diagnostic-*.json' -File -ErrorAction SilentlyContinue | ForEach-Object FullName)
}
function Assert-CanonicalDeclarationRefused([object]$Case, [string]$ExpectedText, [string[]]$ReceiptsBefore) {
  Assert-Refused $Case $ExpectedText
  $receiptsAfter=Get-DiagnosticReceiptPaths
  $newReceipts=@($receiptsAfter | Where-Object { $_ -notin $ReceiptsBefore })
  Assert-True ($newReceipts.Count -eq 0) "canonical declaration refusal writes no receipt (new=$($newReceipts -join ';'))"
}
function Assert-CanonicalPreloadRefused([object]$Case, [string]$ExpectedText) {
  Assert-True ($Case.Result.Code -eq 73) "canonical preload refusal uses exit 73 (actual=$($Case.Result.Code) stderr=$($Case.Result.Stderr))"
  Assert-True ($Case.Result.Stderr -match [regex]::Escape($ExpectedText)) "canonical preload refusal names '$ExpectedText' (stderr=$($Case.Result.Stderr))"
  Assert-True (-not (Test-Path -LiteralPath $Case.Marker)) 'canonical preload refusal leaves no body marker'
  Assert-True (-not (Test-Path -LiteralPath $lockRoot)) 'canonical preload refusal releases its lock'
}
function Invoke-CanonicalDiagnostic([string]$MarkerName, [hashtable]$Overrides=@{}, [hashtable]$ChildEnvironment=@{}, [string]$GuardPath='') {
  $receiptsBefore=Get-DiagnosticReceiptPaths
  $parameters=@{ '-DiagnosticScriptPath'=$null; '-DiagnosticSha256'=$null; '-DiagnosticBudgetSeconds'='600' }
  foreach ($entry in $Overrides.GetEnumerator()) { $parameters[$entry.Key]=$entry.Value }
  $case=Invoke-Diagnostic $parameters $MarkerName $ChildEnvironment 'canonical-vitest-residual-v1' $GuardPath
  Add-Member -InputObject $case -NotePropertyName ReceiptsBefore -NotePropertyValue $receiptsBefore
  return $case
}
function Assert-TmpPackageRuns($Case) {
  Assert-True ($Case.Result.Code -eq 0 -and (Test-Path -LiteralPath $Case.Marker)) "tmp-package-clean-exact-head-must-admit: packaged diagnostic runs (exit=$($Case.Result.Code) stderr=$($Case.Result.Stderr))"
}
function Assert-UndeclaredSiblingRefused($Case) {
  Assert-True ($Case.Result.Code -eq 73 -and $Case.Result.Stderr.Contains('diagnostic module was not tracked at the bound head or under an admitted node_modules directory:') -and
    -not (Test-Path -LiteralPath $Case.Marker)) "undeclared-sibling-must-refuse: exit=73 named module refusal and no body side effect (exit=$($Case.Result.Code) stderr=$($Case.Result.Stderr))"
}
function Assert-DependencySwapRefused($Case) {
  Assert-True ($Case.Result.Code -eq 73 -and $Case.Result.Stderr.Contains('declared diagnostic dependency changed before evaluation:') -and
    -not (Test-Path -LiteralPath $Case.Marker)) "dependency-swap-must-refuse: loaded bytes must match declaration before body (exit=$($Case.Result.Code) stderr=$($Case.Result.Stderr))"
}
function Assert-ClosureMutantKilled($Case, [string]$Name, [scriptblock]$Assertion, [string]$AssertionName) {
  # A mutant must reach the real payload successfully, not fail due to bad setup.
  Assert-True ($Case.Result.Code -eq 0 -and (Test-Path -LiteralPath $Case.Marker)) "$Name-mutant-launched: real verifier and payload completed (exit=$($Case.Result.Code) stderr=$($Case.Result.Stderr))"
  $failed=$false
  try { & $Assertion $Case } catch {
    if (-not $_.Exception.Message.StartsWith("ASSERTION FAILED: $AssertionName`:")) { throw }
    $failed=$true
  }
  Assert-True $failed "$Name mutant must fail its named policy assertion"
  Write-Output "KILLED mutant $Name at assertion=$AssertionName launched=1 payload-exit=0 body-side-effect=1"
}
function Set-TestVerifierSubstitution([string]$Path, [string]$Anchor, [string]$Replacement, [string]$Name) {
  $text=[IO.File]::ReadAllText($Path)
  $count=([regex]::Matches($text,[regex]::Escape($Anchor))).Count
  Assert-True ($count -eq 1) "$Name`: mechanical substitution matched exactly once (count=$count)"
  [IO.File]::WriteAllText($Path,$text.Replace($Anchor,$Replacement))
}
function Test-DiagnosticDescendantSnapshot {
  $snapshotGuard=New-TestOnlyDiagnosticGuard 'descendant-snapshot'
  Set-TestVerifierSubstitution $snapshotGuard '@(Get-CimInstance Win32_Process -ErrorAction Stop)' '@($script:testDiagnosticSnapshot)' 'descendant-snapshot-copy'
  $driver=Join-Path $root 'descendant-snapshot-driver.ps1'
  Set-Content -LiteralPath $driver -Value @'
param([string]$Verifier)
$ErrorActionPreference='Stop'
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($Verifier,[ref]$tokens,[ref]$errors)
if ($errors.Count) { throw 'snapshot driver source must parse' }
$definitions=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst]},$false))
foreach ($definition in $definitions | Where-Object Name -In @('Write-DiagnosticProcessAmbiguity','Test-DiagnosticSnapshotStart','Get-DiagnosticDescendantPids')) {
  . ([scriptblock]::Create($definition.Extent.Text))
}
$instant=[datetime]::SpecifyKind([datetime]'2026-01-01',[DateTimeKind]::Utc)
$rootStart=$instant.AddTicks(7)
function Get-Process([int]$Id) { if($Id -ne 100){throw 'unexpected synthetic PID'}; return [pscustomobject]@{StartTime=$rootStart} }
function Row([int]$Id,[int]$Parent,$Creation) { [pscustomobject]@{ProcessId=$Id;ParentProcessId=$Parent;CreationDate=$Creation;Name='fixture.exe'} }
$script:testDiagnosticSnapshot=@(
  (Row 100 99 $instant),
  (Row 101 100 $instant.AddSeconds(10)),
  (Row 102 101 ([Management.ManagementDateTimeConverter]::ToDmtfDateTime($instant.AddSeconds(20)))),
  (Row 103 100 $instant.AddDays(-4)),
  (Row 104 100 ([Management.ManagementDateTimeConverter]::ToDmtfDateTime($instant.AddDays(-4)))),
  (Row 105 101 $instant.AddSeconds(5)),
  (Row 106 100 'unparseable'),
  (Row 107 100 ([datetimeoffset]$instant)),
  (Row 108 999 $instant.AddSeconds(40)),
  (Row 109 106 $instant.AddSeconds(30)),
  (Row 110 111 $instant.AddSeconds(60)),
  (Row 111 110 $instant.AddSeconds(60)),
  (Row 112 101 $instant.AddSeconds(10))
)
$ids=@(Get-DiagnosticDescendantPids 100 $rootStart.Ticks)
Write-Output "FIXTURE descendant-snapshot-classified ids=$($ids -join ',')"
if (106 -in $ids -or 107 -in $ids -or 109 -in $ids) { throw 'ASSERTION FAILED: descendant-unparseable-must-exclude' }
if (103 -in $ids -or 104 -in $ids -or 105 -in $ids) { throw 'ASSERTION FAILED: descendant-parent-order-must-hold' }
if (($ids | Sort-Object) -join ',' -cne '101,102,112') { throw 'ASSERTION FAILED: descendant-exact-root-chain-must-bind' }
$script:testDiagnosticSnapshot=@((Row 100 99 $instant.AddSeconds(30)),(Row 101 100 $instant.AddSeconds(40)))
$rootStart=$instant.AddSeconds(30)
if (@(Get-DiagnosticDescendantPids 100 $instant.AddTicks(7).Ticks).Count) { throw 'ASSERTION FAILED: descendant-reused-root-must-exclude' }
$script:testDiagnosticSnapshot=@((Row 101 100 $instant.AddSeconds(40)))
if (@(Get-DiagnosticDescendantPids 100 $rootStart.Ticks).Count) { throw 'ASSERTION FAILED: descendant-missing-root-must-exclude' }
Write-Output 'PASS descendant snapshot DateTime=1 DMTF=1 ambiguous=excluded pre-root=excluded every-hop=checked exact-root=checked'
'@
  $result=Invoke-Child @('-NoProfile','-File',$driver,'-Verifier',$snapshotGuard)
  Assert-True ($result.Code -eq 0 -and $result.Stdout.Contains('FIXTURE descendant-snapshot-classified') -and
    $result.Stderr.Contains('creation-time-unparseable') -and $result.Stderr.Contains('parent-creation-order') -and
    $result.Stderr.Contains('root-start-identity-mismatch')) "descendant-snapshot-must-classify: production function and ambiguity log (exit=$($result.Code) stdout=$($result.Stdout) stderr=$($result.Stderr))"
  Write-Output $result.Stdout.Trim()
  foreach ($mutant in @(
    @{name='empty-catch-include';anchor="catch { Write-DiagnosticProcessAmbiguity `$processId 'creation-time-unparseable'; `$excluded[`$processId] = `$true; continue }";replacement='catch { $createdTicks = $RootStartTicks }';assertion='descendant-unparseable-must-exclude'},
    @{name='missing-creation-order';anchor='if ($candidate.StartTicks -lt $parent.StartTicks) {';replacement='if ($false) {';assertion='descendant-parent-order-must-hold'}
  )) {
    $mutantGuard=New-TestOnlyDiagnosticGuard "descendant-$($mutant.name)"
    Set-TestVerifierSubstitution $mutantGuard '@(Get-CimInstance Win32_Process -ErrorAction Stop)' '@($script:testDiagnosticSnapshot)' 'descendant-mutant-snapshot-copy'
    Set-TestVerifierSubstitution $mutantGuard $mutant.anchor $mutant.replacement "descendant-$($mutant.name)-mutant"
    $result=Invoke-Child @('-NoProfile','-File',$driver,'-Verifier',$mutantGuard)
    Assert-True ($result.Code -eq 1 -and $result.Stdout.Contains('FIXTURE descendant-snapshot-classified') -and
      $result.Stderr.Contains("ASSERTION FAILED: $($mutant.assertion)")) "descendant-$($mutant.name)-mutant-launched: named assertion, not setup (exit=$($result.Code) stdout=$($result.Stdout) stderr=$($result.Stderr))"
    Write-Output "KILLED mutant $($mutant.name) at assertion=$($mutant.assertion) classified=1 exit=1"
  }
}
function Assert-DiagnosticStaleIdentityProtected($Stale, $Result) {
  Assert-True (-not $Stale.Process.HasExited -and $Stale.Process.StartTime.ToUniversalTime().Ticks -eq $Stale.StartTicks -and
    $Result.Stderr.Contains("diagnostic process kill skipped pid=$($Stale.Process.Id) reason=start-identity-mismatch")) 'diagnostic-stale-identity-must-not-kill: fixture-owned stale identity survives timeout and is logged'
}
function Test-DiagnosticStaleIdentityTimeout {
  foreach ($mutant in @($false,$true)) {
    $name=if($mutant){'kill-without-identity-check'}else{'stale-identity-timeout'}
    $staleRelease=Join-Path $root "$name.stale-release"; $staleReady=Join-Path $root "$name.stale-ready"
    $stale=Start-TestChild @('-NoProfile','-Command', '[IO.File]::WriteAllText($env:DIAGNOSTIC_STALE_READY,"ready"); while(-not(Test-Path -LiteralPath $env:DIAGNOSTIC_STALE_RELEASE)){Start-Sleep -Milliseconds 25}') @{
      DIAGNOSTIC_STALE_RELEASE=$staleRelease; DIAGNOSTIC_STALE_READY=$staleReady
    }
    $run=$null
    try {
      $watch=[Diagnostics.Stopwatch]::StartNew()
      while (-not (Test-Path -LiteralPath $staleReady) -and -not $stale.Process.HasExited -and $watch.ElapsedMilliseconds -lt 15000) { Start-Sleep -Milliseconds 25 }
      Assert-True ((Test-Path -LiteralPath $staleReady) -and -not $stale.Process.HasExited) 'stale-identity-fixture-ready: only a live process created by this test is the kill target'
      $staleGuard=New-TestOnlyDiagnosticGuard $name
      $anchor='$script:diagnosticObservedDescendantStarts = @{}'
      $injection=@'
$script:diagnosticObservedDescendantStarts = @{}
$testStalePid = [int]$env:DIAGNOSTIC_STALE_PID
$script:diagnosticObservedDescendantStarts[$testStalePid] = [long]$env:DIAGNOSTIC_STALE_START
$diagnosticObservedDescendants += $testStalePid
'@
      Set-TestVerifierSubstitution $staleGuard $anchor $injection 'stale-identity-recorded-start-copy'
      if ($mutant) {
        Set-TestVerifierSubstitution $staleGuard 'if ($StartTicks -le 0 -or $candidate.StartTime.ToUniversalTime().Ticks -ne $StartTicks) {' 'if ($false) {' 'kill-without-identity-check-mutant'
      }
      $run=New-BarrierDiagnostic $staleGuard $name -ChildEnvironment @{
        DIAGNOSTIC_STALE_PID=[string]$stale.Process.Id; DIAGNOSTIC_STALE_START=[string]($stale.StartTicks - [TimeSpan]::TicksPerSecond)
      }
      Wait-BarrierDiagnostic $run
      Set-DiagnosticClock $run.Clock ([DateTimeOffset]::UtcNow.AddSeconds(901))
      $outcome=Wait-DiagnosticBudgetOutcome $run
      Assert-DiagnosticTimeoutExit $outcome 'stale-identity-real-timeout-must-complete'
      $receipts=@(Get-ChildItem -LiteralPath $artifactRoot -Filter 'host-heavy-diagnostic-*.json' -File | Where-Object FullName -NotIn $run.ReceiptsBefore)
      Assert-True ($receipts.Count -eq 1) 'stale-identity-real-timeout-receipt: one new receipt, no setup refusal'
      $record=Get-Content -LiteralPath $receipts[0].FullName -Raw | ConvertFrom-Json
      Assert-True ($record.exit -eq 124 -and $record.timedOut -eq $true -and -not (Test-Path -LiteralPath $lockRoot) -and
        $run.Processes[0].HasExited) 'stale-identity-real-timeout-receipt: real budget expiry, owned child death and lock release'
      if ($mutant) {
        Assert-True ($stale.Process.WaitForExit(5000)) 'kill-without-identity-check-mutant-launched: real timeout killed only the fixture-owned stale process'
        $failed=$false
        try { Assert-DiagnosticStaleIdentityProtected $stale $outcome.Result } catch {
          if (-not $_.Exception.Message.StartsWith('ASSERTION FAILED: diagnostic-stale-identity-must-not-kill:')) { throw }
          $failed=$true
        }
        Assert-True $failed 'kill-without-identity-check mutant must fail the named survival assertion'
        Write-Output 'KILLED mutant kill-without-identity-check at assertion=diagnostic-stale-identity-must-not-kill launched=1 timeout-exit=124 fixture-owned-stale-killed=1'
      } else {
        Assert-DiagnosticStaleIdentityProtected $stale $outcome.Result
        Write-Output 'PASS diagnostic-stale-identity-must-not-kill timeout-exit=124 stale-alive=1 mismatch-logged=1 child-dead=1 lock-released=1'
      }
    } finally {
      if ($run) { Close-BarrierDiagnostic $run }
      New-Item -ItemType File -Path $staleRelease -Force | Out-Null
      if (-not $stale.Process.WaitForExit(5000)) { Stop-TestExactProcess $stale.Process $stale.StartTicks }
    }
  }
}
function Assert-RepeatImportRefused($Case, [string]$ExpectedMessage) {
  Assert-True ($Case.Result.Code -eq 73 -and $Case.Result.Stderr.Contains($ExpectedMessage) -and
    -not (Test-Path -LiteralPath $Case.Marker)) "repeat-import-must-recheck-loaded-bytes: second load refuses before changed body (exit=$($Case.Result.Code) stderr=$($Case.Result.Stderr))"
}
function Test-RepeatDiagnosticImports {
  $worktree=Join-Path $container 'repeat-import-lane'
  $artifactRoot=Join-Path $worktree '.orchestrator/artifacts'
  $packageRoot=Join-Path $worktree '.tmp/repeat'
  New-Item -ItemType Directory -Path $worktree, $artifactRoot, $packageRoot, (Join-Path $worktree 'node_modules/repeat') -Force | Out-Null
  Set-Content -LiteralPath (Join-Path $worktree '.gitignore') -Value @('/.tmp/', '/node_modules/', '/.orchestrator/artifacts/')
  Set-Content -LiteralPath (Join-Path $packageRoot 'package.json') -Value '{"type":"commonjs"}'
  $trackedPath=Join-Path $worktree 'tracked.mjs'
  $esmOriginal='export const value = 1;'
  [IO.File]::WriteAllText($trackedPath, $esmOriginal)
  Invoke-FixtureGit @('init','--initial-branch=codex/test') | Out-Null
  Invoke-FixtureGit @('config','user.name','Diagnostic Admission Test') | Out-Null
  Invoke-FixtureGit @('config','user.email','diagnostic-admission@example.invalid') | Out-Null
  Invoke-FixtureGit @('add','--','.gitignore','tracked.mjs') | Out-Null
  Invoke-FixtureGit @('commit','-m','repeat import fixture') | Out-Null
  $head=Invoke-FixtureGit @('rev-parse','HEAD')
  $scriptRelative='.tmp/repeat/control.mjs'; $scriptPath=Join-Path $worktree $scriptRelative
  $entrySource=@'
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
const target = new URL(process.env.REPEAT_TARGET, import.meta.url);
const mode = process.env.REPEAT_MODE;
const require = createRequire(import.meta.url);
async function load(suffix) {
  if (mode.startsWith('commonjs')) {
    const filename = require.resolve(fileURLToPath(target));
    delete require.cache[filename];
    return require(filename);
  }
  return import(target.href + suffix, mode === 'json' ? { with: { type: 'json' } } : undefined);
}
for (const suffix of ['', '?unchanged=1#unchanged']) {
  const first = await load(suffix);
  assert.equal((mode === 'json' ? first.default : first).value, 1, 'repeat-import-first-load');
}
fs.writeFileSync(process.env.DIAGNOSTIC_MARKER + '.first', 'original-loaded');
fs.writeFileSync(target, process.env.REPEAT_CHANGED);
fs.writeFileSync(process.env.DIAGNOSTIC_MARKER + '.second', 'second-import-reached');
await load(process.env.REPEAT_SUFFIX);
// JSON has no executable body; this marker proves changed JSON reached the caller.
fs.writeFileSync(process.env.DIAGNOSTIC_MARKER, 'changed-bytes-returned');
'@
  $esmChanged="import fs from 'node:fs'; fs.writeFileSync(process.env.DIAGNOSTIC_MARKER, 'changed-body'); export const value = 2;"
  $cases=@(
    @{ name='declared-query'; relative='.tmp/repeat/dep.mjs'; target='./dep.mjs'; mode='esm'; suffix='?second=1#changed'; declared=$true },
    @{ name='declared-fragment'; relative='.tmp/repeat/dep.mjs'; target='./dep.mjs'; mode='esm'; suffix='#changed'; declared=$true },
    @{ name='tracked-query'; relative='tracked.mjs'; target='../../tracked.mjs'; mode='esm'; suffix='?second=1' },
    @{ name='node-modules-fragment'; relative='node_modules/repeat/index.mjs'; target='../../node_modules/repeat/index.mjs'; mode='esm'; suffix='#changed' },
    @{ name='json-query'; relative='.tmp/repeat/dep.json'; target='./dep.json'; mode='json'; suffix='?second=1'; declared=$true },
    @{ name='json-fragment'; relative='.tmp/repeat/dep.json'; target='./dep.json'; mode='json'; suffix='#changed'; declared=$true },
    @{ name='commonjs'; relative='.tmp/repeat/dep.js'; target='./dep.js'; mode='commonjs'; suffix=''; declared=$true },
    @{ name='commonjs-json'; relative='.tmp/repeat/dep.json'; target='./dep.json'; mode='commonjs-json'; suffix=''; declared=$true },
    @{ name='node-modules-json'; relative='node_modules/repeat/index.json'; target='../../node_modules/repeat/index.json'; mode='json'; suffix='?second=1#changed' },
    @{ name='node-modules-commonjs'; relative='node_modules/repeat/index.cjs'; target='../../node_modules/repeat/index.cjs'; mode='commonjs'; suffix='' }
  )
  foreach ($fixture in $cases) {
    [IO.File]::WriteAllText($scriptPath, $entrySource)
    $targetPath=Join-Path $worktree $fixture.relative
    $original=if ($fixture.mode -like '*json') { '{"value":1}' } elseif ($fixture.mode -eq 'commonjs') { 'module.exports = { value: 1 };' } else { $esmOriginal }
    $changed=if ($fixture.mode -like '*json') { '{"value":2}' } elseif ($fixture.mode -eq 'commonjs') { "require('node:fs').writeFileSync(process.env.DIAGNOSTIC_MARKER, 'changed-body'); module.exports = { value: 2 };" } else { $esmChanged }
    [IO.File]::WriteAllText($targetPath, $original)
    $originalHash=Get-Sha256 $targetPath
    $scriptHash=Get-Sha256 $scriptPath
    $dependencies=if ($fixture.declared) { @(@{path=$fixture.relative;sha256=$originalHash}) } else { $null }
    Write-Declaration $scriptRelative $scriptHash -Dependencies $dependencies
    Assert-True ((Invoke-FixtureGit @('status','--porcelain=v1','--untracked-files=all')) -ceq '') 'repeat-import-setup: clean exact-head fixture'
    $environment=@{ REPEAT_TARGET=$fixture.target; REPEAT_MODE=$fixture.mode; REPEAT_SUFFIX=$fixture.suffix; REPEAT_CHANGED=$changed }
    $before=@(Get-ChildItem -LiteralPath $artifactRoot -Filter 'host-heavy-diagnostic-*.json' -File | ForEach-Object FullName)
    $case=Invoke-Diagnostic @{} "repeat-$($fixture.name)" $environment 'staged-import-chromium-control'
    Assert-True ((Test-Path -LiteralPath "$($case.Marker).first") -and (Test-Path -LiteralPath "$($case.Marker).second")) "repeat-import-launched: $($fixture.name) first load and second import reached (exit=$($case.Result.Code) stderr=$($case.Result.Stderr))"
    $expected=if ($fixture.declared) { 'declared diagnostic dependency changed before evaluation:' } else { 'diagnostic module changed since its recorded evaluation:' }
    Assert-RepeatImportRefused $case $expected
    $receipts=@(Get-ChildItem -LiteralPath $artifactRoot -Filter 'host-heavy-diagnostic-*.json' -File | Where-Object FullName -NotIn $before)
    # A changed tracked file fails the host's final clean-tree check, so no receipt is allowed there.
    Assert-True ($receipts.Count -eq $(if($fixture.name -eq 'tracked-query'){0}else{1})) 'repeat-import-receipt: no successful stale certification'
    foreach ($receipt in $receipts) {
      $record=Get-Content -LiteralPath $receipt.FullName -Raw | ConvertFrom-Json
      $loaded=@($record.modules | Where-Object { $_.path -ieq $targetPath })
      Assert-True ($record.exit -eq 73 -and $record.nativeExit -eq 73 -and $loaded.Count -eq 1 -and $loaded[0].sha256 -ceq $originalHash -and
        -not (Test-Path -LiteralPath $case.Marker)) 'repeat-import-receipt: one digest binds only evaluated original bytes; changed bytes were refused'
    }
    [IO.File]::WriteAllText($targetPath, $original)
    Write-Output "PASS repeat-import-must-recheck-loaded-bytes case=$($fixture.name) second-import=1 exit=73 changed-body=0 stale-receipt=0"
    if ($fixture.name -eq 'declared-query') {
      $mutantGuard=New-TestOnlyDiagnosticGuard 'repeat-import-cache-shortcut-mutant'
      $mutantPreload=Join-Path (Split-Path -Parent $mutantGuard) 'heavy-admission-preload.cjs'
      $text=[IO.File]::ReadAllText($mutantPreload); $anchor='if (!actual) return;'
      Assert-True (([regex]::Matches($text,[regex]::Escape($anchor))).Count -eq 1) 'repeat-import-mutant-setup: exactly one shortcut insertion target'
      [IO.File]::WriteAllText($mutantPreload, $text.Replace($anchor, 'if (!actual || modules.has(path.resolve(actual).toLowerCase())) return;'))
      $mutant=Invoke-Diagnostic @{} 'repeat-import-cache-shortcut-mutant' $environment 'staged-import-chromium-control' $mutantGuard
      Assert-True ((Test-Path -LiteralPath "$($mutant.Marker).first") -and (Test-Path -LiteralPath "$($mutant.Marker).second")) 'repeat-import-mutant-launched: first evaluation and second import reached'
      Assert-ClosureMutantKilled $mutant 'repeat-import-cache-shortcut' { param($result) Assert-RepeatImportRefused $result 'declared diagnostic dependency changed before evaluation:' } 'repeat-import-must-recheck-loaded-bytes'
      $mutantReceipts=@(Get-ChildItem -LiteralPath $artifactRoot -Filter 'host-heavy-diagnostic-*.json' -File | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json } | Where-Object { $_.exit -eq 0 })
      Assert-True ($mutantReceipts.Count -eq 1 -and @($mutantReceipts[0].modules | Where-Object { $_.path -ieq $targetPath -and $_.sha256 -ceq $originalHash }).Count -eq 1 -and
        (Get-Sha256 $targetPath) -cne $originalHash) 'repeat-import-mutant-stale-receipt: successful second evaluation retained obsolete digest'
      [IO.File]::WriteAllText($targetPath, $original)
    }
  }
  Assert-True ((Invoke-FixtureGit @('status','--porcelain=v1','--untracked-files=all')) -ceq '') 'repeat-import-completed: tracked bytes restored and fixture clean'
}
function Test-IgnoredChromiumPackage {
  $worktree=Join-Path $container 'ignored-package-lane'
  $artifactRoot=Join-Path $worktree '.orchestrator/artifacts'
  New-Item -ItemType Directory -Path $worktree, $artifactRoot -Force | Out-Null
  # Receipts are ignored narrowly; the old operator package path must remain unignored.
  Set-Content -LiteralPath (Join-Path $worktree '.gitignore') -Value @('/.tmp/', '/.orchestrator/artifacts/')
  Invoke-FixtureGit @('init','--initial-branch=codex/test') | Out-Null
  Invoke-FixtureGit @('config','user.name','Diagnostic Admission Test') | Out-Null
  Invoke-FixtureGit @('config','user.email','diagnostic-admission@example.invalid') | Out-Null
  Invoke-FixtureGit @('add','--','.gitignore') | Out-Null
  Invoke-FixtureGit @('commit','-m','ignored package fixture') | Out-Null
  $head=Invoke-FixtureGit @('rev-parse','HEAD')
  $source=Join-Path $root 'fixture-chromium-control.mjs'
  Set-Content -LiteralPath $source -Value @'
import assert from 'node:assert/strict';
import fs from 'node:fs';
fs.writeFileSync(process.env.DIAGNOSTIC_MARKER, `payload-started:${process.env.CHASE_SETS_HEAVY_ADMITTED}`);
assert.equal(process.env.CHASE_SETS_HEAVY_ADMITTED, '1', 'diagnostic-admitted-env-must-be-one');
if (process.env.DIAGNOSTIC_EXPECT_INPUTS === '1') {
  assert.equal(process.env.CHROME, 'fixture chrome path with spaces', 'diagnostic-chrome-passthrough');
  assert.equal(process.env.OPENSSL, 'fixture openssl path with spaces', 'diagnostic-openssl-passthrough');
}
'@
  $scriptRelative=[string]$chromiumDeclaration.path
  $scriptPath=Join-Path $worktree $scriptRelative
  New-Item -ItemType Directory -Path (Split-Path -Parent $scriptPath) -Force | Out-Null
  Copy-Item -LiteralPath $source -Destination $scriptPath
  $scriptHash=Get-Sha256 $scriptPath; Write-Declaration $scriptRelative $scriptHash
  Assert-True ((Invoke-FixtureGit @('ls-files','--',$scriptRelative)) -ceq '') 'tmp-package-setup: copied script is not tracked'
  Assert-True ((Invoke-FixtureGit @('status','--porcelain=v1','--untracked-files=all')) -ceq '') 'tmp-package-setup: copied ignored package leaves exact-head fixture clean'
  $case=Invoke-Diagnostic @{} 'tmp-package' @{} 'staged-import-chromium-control'
  Assert-TmpPackageRuns $case
  $receipts=@(Get-ChildItem -LiteralPath $artifactRoot -Filter 'host-heavy-diagnostic-*.json' -File)
  Assert-True ($receipts.Count -eq 1) 'tmp-package-receipt: admitted script writes one durable receipt'
  $record=Get-Content -LiteralPath $receipts[0].FullName -Raw | ConvertFrom-Json -DateKind String
  Assert-True ($record.head -ceq $head -and $record.diagnostic.name -ceq 'staged-import-chromium-control' -and
    $record.diagnostic.scriptPath -ceq $scriptRelative -and $record.diagnostic.sha256 -ceq $scriptHash -and
    $record.exit -eq 0 -and $record.nativeExit -eq 0 -and $record.timedOut -eq $false -and
    -not (Test-Path -LiteralPath $lockRoot)) 'tmp-package-receipt: exact head, pinned path, fixture hash and native exit bind'
  Assert-True ((Invoke-FixtureGit @('status','--porcelain=v1','--untracked-files=all')) -ceq '') 'tmp-package-completed: receipt leaves exact-head fixture clean'
  Write-Output 'PASS diagnostic tmp-package clean-exact-head=1 untracked-ignored=1 real-route=1 receipt=1 exit=0'

  $environmentCase=Invoke-Diagnostic @{} 'diagnostic-admitted-env-overwrite' @{
    CHASE_SETS_HEAVY_ADMITTED='0'; CHROME='fixture chrome path with spaces'; OPENSSL='fixture openssl path with spaces'; DIAGNOSTIC_EXPECT_INPUTS='1'
  } 'staged-import-chromium-control'
  Assert-TmpPackageRuns $environmentCase
  Assert-True ((Get-Content -LiteralPath $environmentCase.Marker -Raw) -ceq 'payload-started:1') 'diagnostic-admitted-env-overwrite: caller zero becomes one in the real payload'
  Write-Output 'PASS diagnostic-admitted-env-must-be-one caller-zero=overwritten CHROME=unchanged OPENSSL=unchanged exit=0'

  Add-Content -LiteralPath $scriptPath -Value '// hash mismatch must refuse before the flag-asserting payload starts'
  Assert-True ((Get-Sha256 $scriptPath) -cne $scriptHash) 'diagnostic-admitted-env-refusal-setup: bytes differ from declaration'
  $refusedEnvironment=Invoke-Diagnostic @{} 'diagnostic-admitted-env-refused' @{ CHASE_SETS_HEAVY_ADMITTED='1' } 'staged-import-chromium-control'
  Assert-Refused $refusedEnvironment 'declared diagnostic SHA-256 does not match the script'
  Copy-Item -LiteralPath $source -Destination $scriptPath -Force
  Write-Output 'PASS diagnostic-admitted-env-refusal hash-mismatch=73 payload-started=0 caller-one-cannot-admit=1'

  $environmentGuard=New-TestOnlyDiagnosticGuard 'diagnostic-admitted-env-mutant'
  $guardText=[IO.File]::ReadAllText($environmentGuard)
  $anchor='$start.Environment["CHASE_SETS_HEAVY_ADMITTED"] = "1"'
  Assert-True (([regex]::Matches($guardText,[regex]::Escape($anchor))).Count -eq 1) 'diagnostic-admitted-env-mutant-setup: exactly one assignment target'
  [IO.File]::WriteAllText($environmentGuard, $guardText.Replace($anchor, '# mutant: drop diagnostic admission environment assignment'))
  $environmentMutant=Invoke-Diagnostic @{} 'diagnostic-admitted-env-mutant' @{ CHASE_SETS_HEAVY_ADMITTED='0' } 'staged-import-chromium-control' $environmentGuard
  Assert-True ($environmentMutant.Result.Code -eq 1 -and (Test-Path -LiteralPath $environmentMutant.Marker) -and
    (Get-Content -LiteralPath $environmentMutant.Marker -Raw) -ceq 'payload-started:0' -and
    $environmentMutant.Result.Stderr.Contains('diagnostic-admitted-env-must-be-one') -and
    $environmentMutant.Result.Stderr.Contains('AssertionError')) "diagnostic-admitted-env-mutant-launched: payload must fail its named assertion, not setup (exit=$($environmentMutant.Result.Code) stderr=$($environmentMutant.Result.Stderr))"
  Write-Output 'KILLED mutant drop-diagnostic-admitted-env at assertion=diagnostic-admitted-env-must-be-one launched=1 payload-reached=1 child-value=0 payload-exit=1'

  $packageRoot=Split-Path -Parent $scriptPath
  $compiled=Join-Path $packageRoot 'compiled'
  New-Item -ItemType Directory -Path $compiled -Force | Out-Null
  [IO.File]::WriteAllText((Join-Path $packageRoot 'package.json'), '{"type":"module"}')
  Set-Content -LiteralPath (Join-Path $packageRoot 'runtime.mjs') -Value "export { value } from './compiled/a.js';"
  Set-Content -LiteralPath (Join-Path $compiled 'a.js') -Value "export { value } from './b.js';"
  $bPath=Join-Path $compiled 'b.js'
  $bSource="import fs from 'node:fs'; fs.writeFileSync(process.env.DIAGNOSTIC_MARKER, 'dependency-body'); export const value = 1;"
  Set-Content -LiteralPath $bPath -Value $bSource
  $closureSource="import { value } from './runtime.mjs'; if (value !== 1) throw new Error('bad-closure');"
  Set-Content -LiteralPath $scriptPath -Value $closureSource
  $scriptHash=Get-Sha256 $scriptPath
  $dependencies=@('runtime.mjs','compiled/a.js','compiled/b.js') | ForEach-Object {
    @{ path=".tmp/operator-7334-staged-import/$_"; sha256=(Get-Sha256 (Join-Path $packageRoot $_)) }
  }
  Write-Declaration $scriptRelative $scriptHash -Dependencies $dependencies
  Assert-True ((Invoke-FixtureGit @('status','--porcelain=v1','--untracked-files=all')) -ceq '') 'dependency-closure-setup: ignored siblings and package metadata leave exact-head fixture clean'
  $closure=Invoke-Diagnostic @{} 'dependency-closure' @{} 'staged-import-chromium-control'
  Assert-TmpPackageRuns $closure
  $closureReceipt=@(Get-ChildItem -LiteralPath $artifactRoot -Filter 'host-heavy-diagnostic-*.json' -File | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json } | Where-Object { $_.diagnostic.sha256 -ceq $scriptHash })
  Assert-True ($closureReceipt.Count -eq 1 -and $closureReceipt[0].diagnostic.dependencies.Count -eq 3 -and $closureReceipt[0].modules.Count -eq 4) 'dependency-closure-receipt: entry and all three loaded modules bind; package.json does not pass through module hooks'
  foreach ($dependency in $dependencies) {
    $declared=@($closureReceipt[0].diagnostic.dependencies | Where-Object path -CEQ $dependency.path)
    $loaded=@($closureReceipt[0].modules | Where-Object { $_.path -ieq (Join-Path $worktree $dependency.path) })
    Assert-True ($declared.Count -eq 1 -and $declared[0].sha256 -ceq $dependency.sha256 -and $loaded.Count -eq 1 -and $loaded[0].sha256 -ceq $dependency.sha256) 'dependency-closure-receipt: declared and loaded dependency hashes bind'
  }
  Write-Output 'PASS dependency-closure clean-exact-head=1 runtime.mjs->a.js->b.js=1 receipt-hashes=3 exit=0 package.json-hook=0'

  $invalidDependencies=@(
    @{ name='not-array'; value=@{ path=$dependencies[0].path; sha256=$dependencies[0].sha256 }; message='diagnostic dependencies must be an array of at most 64 entries' },
    @{ name='null'; value=$null; message='diagnostic dependencies must be an array of at most 64 entries' },
    @{ name='too-many'; value=@(1..65 | ForEach-Object { $dependencies[0] }); message='diagnostic dependencies must be an array of at most 64 entries' },
    @{ name='duplicate'; value=@($dependencies[0],$dependencies[0]); message='diagnostic dependency duplicates another dependency or the entry' },
    @{ name='duplicate-case'; value=@($dependencies[0],@{path=$dependencies[0].path.ToUpperInvariant().Replace('.MJS','.mjs');sha256=$dependencies[0].sha256}); message='diagnostic dependency duplicates another dependency or the entry' },
    @{ name='entry'; value=@(@{path=$scriptRelative;sha256=$scriptHash}); message='diagnostic dependency duplicates another dependency or the entry' },
    @{ name='parent'; value=@(@{path='.tmp/../runtime.mjs';sha256=$dependencies[0].sha256}); message='diagnostic dependency must be a repository-relative .mjs, .js or .json path' },
    @{ name='absolute'; value=@(@{path=(Join-Path $packageRoot 'runtime.mjs');sha256=$dependencies[0].sha256}); message='diagnostic dependency must be a repository-relative .mjs, .js or .json path' },
    @{ name='extension'; value=@(@{path='.tmp/runtime.txt';sha256=$dependencies[0].sha256}); message='diagnostic dependency must be a repository-relative .mjs, .js or .json path' },
    @{ name='hash'; value=@(@{path=$dependencies[0].path;sha256='not-a-hash'}); message='diagnostic dependency has an invalid SHA-256' },
    @{ name='missing'; value=@(@{path='.tmp/missing.json';sha256=$dependencies[0].sha256}); message='declared diagnostic dependency was not found' }
  )
  foreach ($invalid in $invalidDependencies) {
    Write-Declaration $scriptRelative $scriptHash
    $declaration=Get-Content -LiteralPath $declarationPath -Raw | ConvertFrom-Json
    $declaration.diagnostics.'staged-import-chromium-control' | Add-Member -NotePropertyName dependencies -NotePropertyValue $invalid.value
    [IO.File]::WriteAllText($declarationPath, ($declaration | ConvertTo-Json -Depth 8))
    Assert-Refused (Invoke-Diagnostic @{} "dependency-invalid-$($invalid.name)" @{} 'staged-import-chromium-control') $invalid.message
  }
  Write-Output "PASS dependency-validation negative-cases=$($invalidDependencies.Count) exit=73 no-body=1"

  Write-Declaration $scriptRelative $scriptHash -Dependencies $dependencies[0..1]
  $undeclared=Invoke-Diagnostic @{} 'undeclared-sibling' @{} 'staged-import-chromium-control'
  Assert-UndeclaredSiblingRefused $undeclared
  Write-Output 'PASS undeclared-sibling-must-refuse exit=73 named-message=1 body-side-effect=0'
  $siblingGuard=New-TestOnlyDiagnosticGuard 'ignored-sibling-mutant'
  $siblingPreload=Join-Path (Split-Path -Parent $siblingGuard) 'heavy-admission-preload.cjs'
  $preloadText=[IO.File]::ReadAllText($siblingPreload)
  $anchor='!samePath(actual, entry) && !declaredDependency(actual) &&'
  Assert-True (([regex]::Matches($preloadText,[regex]::Escape($anchor))).Count -eq 1) 'ignored-sibling-mutant-setup: exactly one authorization target'
  [IO.File]::WriteAllText($siblingPreload, $preloadText.Replace($anchor, '!samePath(actual, entry) && !inside(path.dirname(entry), actual) && !declaredDependency(actual) &&'))
  $mutant=Invoke-Diagnostic @{} 'ignored-sibling-mutant' @{} 'staged-import-chromium-control' $siblingGuard
  Assert-ClosureMutantKilled $mutant 'allow-ignored-sibling' ${function:Assert-UndeclaredSiblingRefused} 'undeclared-sibling-must-refuse'

  Write-Declaration $scriptRelative $scriptHash -Dependencies $dependencies
  Set-Content -LiteralPath $bPath -Value ($bSource + '// changed before launch')
  $changed=Invoke-Diagnostic @{} 'dependency-before-launch' @{} 'staged-import-chromium-control'
  Assert-Refused $changed 'declared diagnostic dependency SHA-256 does not match:'
  Write-Output 'PASS dependency-before-launch-must-refuse exit=73 body-side-effect=0'
  Set-Content -LiteralPath $bPath -Value $bSource

  # The entry swaps b.js only after launch, immediately before dynamic import.
  $swapSource="import fs from 'node:fs'; fs.writeFileSync(new URL('./compiled/b.js', import.meta.url), " + (ConvertTo-Json ($bSource + '// swapped after launch') -Compress) + "); await import('./runtime.mjs');"
  Set-Content -LiteralPath $scriptPath -Value $swapSource
  $scriptHash=Get-Sha256 $scriptPath
  Write-Declaration $scriptRelative $scriptHash -Dependencies $dependencies
  $swapped=Invoke-Diagnostic @{} 'dependency-after-launch' @{} 'staged-import-chromium-control'
  Assert-DependencySwapRefused $swapped
  Write-Output 'PASS dependency-swap-must-refuse exit=73 named-message=1 body-side-effect=0'
  Set-Content -LiteralPath $bPath -Value $bSource
  $hashGuard=New-TestOnlyDiagnosticGuard 'dependency-hash-mutant'
  $hashPreload=Join-Path (Split-Path -Parent $hashGuard) 'heavy-admission-preload.cjs'
  $preloadText=[IO.File]::ReadAllText($hashPreload)
  $anchor='if (dependency && sha256 !== dependency.sha256) {'
  Assert-True (([regex]::Matches($preloadText,[regex]::Escape($anchor))).Count -eq 1) 'dependency-hash-mutant-setup: exactly one loaded-byte hash target'
  [IO.File]::WriteAllText($hashPreload, $preloadText.Replace($anchor, 'if (false) {'))
  $mutant=Invoke-Diagnostic @{} 'dependency-hash-mutant' @{} 'staged-import-chromium-control' $hashGuard
  Assert-ClosureMutantKilled $mutant 'skip-dependency-hash' ${function:Assert-DependencySwapRefused} 'dependency-swap-must-refuse'
  Assert-True ((Invoke-FixtureGit @('status','--porcelain=v1','--untracked-files=all')) -ceq '') 'dependency-closure-completed: fixture remains clean'

  # Preserve the built-in-only clean-seat path mutant with its original bytes.
  $scriptHash=Get-Sha256 $source
  $receiptCount=@(Get-ChildItem -LiteralPath $artifactRoot -Filter 'host-heavy-diagnostic-*.json' -File).Count
  $scriptRelative='.orchestrator/operator-7334-staged-import/chromium-control.mjs'
  $mutantPath=Join-Path $worktree $scriptRelative
  New-Item -ItemType Directory -Path (Split-Path -Parent $mutantPath) -Force | Out-Null
  Copy-Item -LiteralPath $source -Destination $mutantPath
  Write-Declaration $scriptRelative $scriptHash
  Assert-True ((Get-Sha256 $mutantPath) -ceq $scriptHash -and (Invoke-FixtureGit @('rev-parse','HEAD')) -ceq $head) 'nonignored-package-mutant-setup: same script bytes and committed head'
  Assert-True ((Invoke-FixtureGit @('status','--porcelain=v1','--untracked-files=all')) -ceq "?? $scriptRelative") 'nonignored-package-mutant-setup: only the old package path dirties the fixture'
  $mutant=Invoke-Diagnostic @{} 'nonignored-package-mutant' @{} 'staged-import-chromium-control'
  Assert-Refused $mutant 'host verifier requires a clean exact-head worktree'
  Assert-True (@(Get-ChildItem -LiteralPath $artifactRoot -Filter 'host-heavy-diagnostic-*.json' -File).Count -eq $receiptCount) 'nonignored-package-mutant-launched: clean-tree refusal writes no new receipt'
  $failed=$false
  try { Assert-TmpPackageRuns $mutant } catch {
    if (-not $_.Exception.Message.StartsWith('ASSERTION FAILED: tmp-package-clean-exact-head-must-admit:')) { throw }
    $failed=$true
    Write-Output $_.Exception.Message
  }
  Assert-True $failed 'nonignored-package-path mutant must fail the named admission assertion after real clean-tree refusal'
  Write-Output 'KILLED mutant nonignored-package-path at assertion=tmp-package-clean-exact-head-must-admit launched=1 clean-exact-head-refusal=1 exit=73'
}
function Write-JsonCensusDeclaration([string]$Hash, [switch]$Release, [switch]$WithoutCensus) {
  # Every other field comes from the release declaration file unchanged.
  $declaration=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'diagnostic-declarations.json') -Raw | ConvertFrom-Json
  if ($WithoutCensus) { $declaration.diagnostics.PSObject.Properties.Remove('json-census-five-run') }
  elseif (-not $Release) { $declaration.diagnostics.'json-census-five-run'.sha256=$Hash }
  [IO.File]::WriteAllText($declarationPath, ($declaration | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
}
function Test-JsonCensusDeclaration {
  $worktree=Join-Path $container 'json-census-lane'
  $artifactRoot=Join-Path $worktree '.orchestrator/artifacts'
  New-Item -ItemType Directory -Path $worktree, $artifactRoot -Force | Out-Null
  Set-Content -LiteralPath (Join-Path $worktree '.gitignore') -Value @('/.tmp/', '/.orchestrator/artifacts/')
  Invoke-FixtureGit @('init','--initial-branch=codex/test') | Out-Null
  Invoke-FixtureGit @('config','user.name','Diagnostic Admission Test') | Out-Null
  Invoke-FixtureGit @('config','user.email','diagnostic-admission@example.invalid') | Out-Null
  Invoke-FixtureGit @('add','--','.gitignore') | Out-Null
  Invoke-FixtureGit @('commit','-m','json census fixture') | Out-Null
  $head=Invoke-FixtureGit @('rev-parse','HEAD')
  $scriptRelative=[string]$censusDeclaration.path
  $scriptPath=Join-Path $worktree $scriptRelative
  $resultPath=Join-Path (Split-Path -Parent $scriptPath) 'census-runner.result.json'
  New-Item -ItemType Directory -Path (Split-Path -Parent $scriptPath) -Force | Out-Null
  # Reads the admission identity with the reviewed runner's exact names and expressions.
  Set-Content -LiteralPath $scriptPath -Value @'
import fs from 'node:fs';
import { fileURLToPath } from 'node:url';
const config = JSON.parse(Buffer.from(process.env.CHASE_SETS_HEAVY_ADMISSION_CONFIG ?? '', 'base64').toString('utf8'));
const slot = process.env.CHASE_SETS_HEAVY_SLOT_ID;
const head = config.diagnostic?.boundHead;
const guessed = ['HEAVY_VERIFIER_ADMISSION_ID', 'HEAVY_ADMISSION_IDENTITY', 'CHASE_SETS_HEAVY_ADMISSION_ID'].filter((name) => Object.hasOwn(process.env, name));
fs.writeFileSync(process.env.DIAGNOSTIC_MARKER, JSON.stringify({ admitted: process.env.CHASE_SETS_HEAVY_ADMITTED ?? null, slot: slot ?? null, head: head ?? null, configHead: config.head ?? null, branch: config.branch ?? null, worktree: config.worktree ?? null, lane: config.lane ?? null, guessed }));
fs.writeFileSync(fileURLToPath(import.meta.url).replace(/\.mjs$/, '.result.json'), `${JSON.stringify({ schema: 'json-census-five-run/v1', exactHead: head })}\n`, { flag: 'wx' });
'@
  $scriptHash=Get-Sha256 $scriptPath
  Assert-True ($scriptHash -cne $censusReviewedSha256) 'json-census-setup: fixture bytes differ from the reviewed runner'
  Assert-True ((Invoke-FixtureGit @('status','--porcelain=v1','--untracked-files=all')) -ceq '') 'json-census-setup: ignored declared path leaves the exact-head fixture clean'

  # The unmodified release declaration admits only the reviewed runner bytes.
  Write-JsonCensusDeclaration -Release
  Assert-Refused (Invoke-Diagnostic @{ '-DiagnosticSha256'=$censusReviewedSha256; '-DiagnosticBudgetSeconds'='600' } 'json-census-release-bytes' @{} 'json-census-five-run') 'declared diagnostic SHA-256 does not match the script'
  Write-Output 'PASS json-census-must-refuse-unreviewed-bytes release-declaration=1 exit=73 body-side-effect=0'

  Write-JsonCensusDeclaration $scriptHash
  $case=Invoke-Diagnostic @{ '-DiagnosticBudgetSeconds'='600' } 'json-census-resolves' @{} 'json-census-five-run'
  Assert-True ($case.Result.Code -eq 0 -and (Test-Path -LiteralPath $case.Marker) -and (Test-Path -LiteralPath $resultPath)) "json-census-must-resolve: declared runner path admits and runs (exit=$($case.Result.Code) stderr=$($case.Result.Stderr))"
  $identity=Get-Content -LiteralPath $case.Marker -Raw | ConvertFrom-Json
  Assert-True ($identity.admitted -ceq '1' -and -not [string]::IsNullOrWhiteSpace([string]$identity.slot) -and $identity.head -ceq $head -and
    $identity.configHead -ceq $head -and $identity.branch -ceq 'codex/test' -and $identity.lane -ceq 'lane-test' -and
    [string]::Equals([string]$identity.worktree, [IO.Path]::GetFullPath($worktree).TrimEnd('\','/'), [StringComparison]::OrdinalIgnoreCase) -and
    @($identity.guessed).Count -eq 0) "json-census-admission-identity: runner names are the ones the verifier sets (identity=$(Get-Content -LiteralPath $case.Marker -Raw))"
  $receipts=@(Get-ChildItem -LiteralPath $artifactRoot -Filter 'host-heavy-diagnostic-*.json' -File)
  Assert-True ($receipts.Count -eq 1) 'json-census-receipt: admitted runner writes one durable receipt'
  $record=Get-Content -LiteralPath $receipts[0].FullName -Raw | ConvertFrom-Json -DateKind String
  Assert-True ($record.head -ceq $head -and $record.diagnostic.name -ceq 'json-census-five-run' -and
    $record.diagnostic.scriptPath -ceq $scriptRelative -and $record.diagnostic.sha256 -ceq $scriptHash -and
    $record.diagnostic.budgetSeconds -eq 600 -and $record.diagnostic.maxBudgetSeconds -eq 600 -and
    $record.exit -eq 0 -and $record.nativeExit -eq 0 -and $record.timedOut -eq $false -and
    $record.resultSha256 -ceq (Get-Sha256 $resultPath) -and -not (Test-Path -LiteralPath $lockRoot)) 'json-census-receipt: name, declared path, hash, 600-second budget, result and release bind'
  Remove-Item -LiteralPath $resultPath -Force
  Assert-True ((Invoke-FixtureGit @('status','--porcelain=v1','--untracked-files=all')) -ceq '') 'json-census-completed: result and receipt leave the exact-head fixture clean'
  Write-Output 'PASS json-census-must-resolve release-entry=1 identity=CHASE_SETS_HEAVY_ADMITTED,CHASE_SETS_HEAVY_SLOT_ID,diagnostic.boundHead guessed-names=0 receipt=1 budget=600 exit=0'

  Assert-Refused (Invoke-Diagnostic @{ '-DiagnosticBudgetSeconds'='601' } 'json-census-over-cap' @{} 'json-census-five-run') 'diagnostic budget exceeds declared maximum'
  Assert-Refused (Invoke-Diagnostic @{ '-DiagnosticSha256'=('0'*64); '-DiagnosticBudgetSeconds'='600' } 'json-census-caller-hash' @{} 'json-census-five-run') 'diagnostic SHA-256 does not match host declaration'
  Assert-Refused (Invoke-Diagnostic @{ '-DiagnosticScriptPath'='.tmp/10761-impl-g4/census-runner.mjs'; '-DiagnosticBudgetSeconds'='600' } 'json-census-lane-path' @{} 'json-census-five-run') 'diagnostic script path does not match host declaration'
  $original=[IO.File]::ReadAllText($scriptPath)
  Add-Content -LiteralPath $scriptPath -Value '// changed after review'
  Assert-Refused (Invoke-Diagnostic @{ '-DiagnosticBudgetSeconds'='600' } 'json-census-changed-bytes' @{} 'json-census-five-run') 'declared diagnostic SHA-256 does not match the script'
  [IO.File]::WriteAllText($scriptPath, $original)
  Assert-True ((Get-Sha256 $scriptPath) -ceq $scriptHash) 'json-census-hash-mismatch: fixture bytes restored'
  Write-Output 'PASS json-census-hash-mismatch-must-refuse caller-hash=73 changed-bytes=73 over-cap=73 lane-path=73 body-side-effect=0'

  foreach ($name in @('JSON-census-five-run', 'json-census-five-run-g4')) {
    Assert-Refused (Invoke-Diagnostic @{ '-DiagnosticBudgetSeconds'='600' } "json-census-undeclared-$name" @{} $name) 'diagnostic name is not declared'
  }
  Write-JsonCensusDeclaration -WithoutCensus
  Assert-Refused (Invoke-Diagnostic @{ '-DiagnosticBudgetSeconds'='600' } 'json-census-removed' @{} 'json-census-five-run') 'diagnostic name is not declared'
  Assert-True (-not (Test-Path -LiteralPath $resultPath) -and @(Get-ChildItem -LiteralPath $artifactRoot -Filter 'host-heavy-diagnostic-*.json' -File).Count -eq 1) 'json-census-refusals: no refusal ran the body or wrote a receipt'
  Write-Output 'PASS json-census-undeclared-must-refuse case-variant=73 suffixed=73 declaration-removed=73 body-side-effect=0'
}

try {
  Assert-NoProductionDiagnosticClockSeam
  Assert-MutantDiagnosticClockSeamIsRejected
  $testGuard=New-TestOnlyDiagnosticGuard
  Write-Output "PASS fixture verifier clock substitution-count=$script:diagnosticClockSubstitutionCount"
  Test-DiagnosticDescendantSnapshot
  Test-RepeatDiagnosticImports
  Test-IgnoredChromiumPackage
  Test-JsonCensusDeclaration
  Set-Content -LiteralPath (Join-Path $worktree '.gitignore') -Value '.orchestrator/'; Set-Content -LiteralPath (Join-Path $worktree 'seed.txt') -Value 'seed'
  Invoke-FixtureGit @('init','--initial-branch=codex/test') | Out-Null; Invoke-FixtureGit @('config','user.name','Diagnostic Admission Test') | Out-Null; Invoke-FixtureGit @('config','user.email','diagnostic-admission@example.invalid') | Out-Null
  Invoke-FixtureGit @('add','--','.') | Out-Null; Invoke-FixtureGit @('commit','-m','fixture') | Out-Null; $head=Invoke-FixtureGit @('rev-parse','HEAD')
  $scriptRelative='.orchestrator/artifacts/diagnostic-success.mjs'; $scriptPath=Join-Path $worktree ($scriptRelative -replace '/','\')
  Set-Content -LiteralPath $scriptPath -Value @'
import fs from 'node:fs';
import { spawn, spawnSync } from 'node:child_process';
const childEnv = { ...process.env };
const sync = spawnSync(process.execPath, ['-e', 'process.stdout.write(process.env.NODE_OPTIONS)'], { windowsHide: true, env: childEnv, encoding: 'utf8' });
if (sync.error || sync.status !== 0 || sync.stdout !== process.env.NODE_OPTIONS) throw new Error('sync child did not inherit the checked preload');
const child = spawn(process.execPath, ['-e', 'process.exit(0)'], { windowsHide: true, env: childEnv });
await new Promise((resolve, reject) => { child.once('error', reject); child.once('exit', (code) => code === 0 ? resolve() : reject(new Error(`async child exit=${code}`))); });
fs.writeFileSync(process.env.DIAGNOSTIC_MARKER, 'ran-after-sync-and-async-children');
fs.writeFileSync(new URL('./diagnostic-success.result.json', import.meta.url), 'result-written-during-run');
process.exitCode = 7;
'@
  $scriptHash=Get-Sha256 $scriptPath; Write-Declaration $scriptRelative $scriptHash

  $resultPath=Join-Path (Split-Path -Parent $scriptPath) 'diagnostic-success.result.json'; Set-Content -LiteralPath $resultPath -Value 'stale-result'
  $staleResult=Invoke-Diagnostic @{} 'stale-result'
  Assert-Refused $staleResult 'diagnostic result file already exists'; Remove-Item -LiteralPath $resultPath -Force
  Write-Output 'PASS diagnostic negative stale-result=1 fresh-marker=1'

  $callerMarker=Join-Path $root 'caller-node-options.marker' | ConvertTo-Json -Compress
  Set-Content -LiteralPath (Join-Path $root 'caller-node-options.cjs') -Value "require('node:fs').writeFileSync($callerMarker,'ran')"
  $success=Invoke-Diagnostic @{} 'success' @{ NODE_OPTIONS="--require=$(Join-Path $root 'caller-node-options.cjs')" }; $receipt=@(Get-ChildItem -LiteralPath $artifactRoot -Filter 'host-heavy-diagnostic-*.json' -File)
  Assert-True ($success.Result.Code -eq 7 -and (Test-Path -LiteralPath $success.Marker)) "declared diagnostic runs (exit=$($success.Result.Code) stderr=$($success.Result.Stderr))"
  Assert-True ($receipt.Count -eq 1) 'declared diagnostic leaves one durable receipt'
  $successReceipt=Get-Content -LiteralPath $receipt[0].FullName -Raw | ConvertFrom-Json -DateKind String
  $resultHash=Get-Sha256 $resultPath
  Assert-True ($successReceipt.schema -ceq 'host-heavy-diagnostic/v1' -and $successReceipt.diagnostic.name -ceq 'worst13-no-fit' -and $successReceipt.diagnostic.kind -ceq 'standalone-node' -and $successReceipt.diagnostic.scriptPath -ceq $scriptRelative -and $successReceipt.diagnostic.sha256 -ceq $scriptHash -and $successReceipt.diagnostic.budgetSeconds -eq 2 -and $successReceipt.containerRoot -ceq ([IO.Path]::GetFullPath($container).TrimEnd('\','/')) -and $successReceipt.declarationSha256 -ceq $scriptHash -and $successReceipt.exit -eq 7 -and $successReceipt.nativeExit -eq 7 -and $successReceipt.timedOut -eq $false -and $successReceipt.resultSha256 -ceq $resultHash -and $successReceipt.resources.peakWorkingSetBytes -gt 0 -and $successReceipt.resources.jobPeakMemoryBytes -ge 0 -and $successReceipt.resources.jobTotalUserTime100ns -ge 0 -and $successReceipt.resources.jobTotalKernelTime100ns -ge 0 -and $successReceipt.resources.jobTotalProcesses -ge 3 -and -not (Test-Path -LiteralPath $lockRoot) -and -not (Test-Path -LiteralPath (Join-Path $root 'caller-node-options.marker'))) 'receipt, result hash, synchronous/asynchronous child resources and preload-only NODE_OPTIONS bind'
  Remove-Item -LiteralPath $resultPath -Force
  Write-Output 'PASS diagnostic declared route receipt=1 exit=7 nativeExit=7 resultSha256=1 jobTotalProcesses-ge-3=1 sync-child=1 async-child=1 preload-only=1 released=1'

  $chromiumRoute=Invoke-Diagnostic @{} 'staged-import-chromium-control' @{} 'staged-import-chromium-control'
  $chromiumReceipts=@(Get-ChildItem -LiteralPath $artifactRoot -Filter 'host-heavy-diagnostic-*.json' -File | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json -DateKind String } | Where-Object { $_.diagnostic.name -ceq 'staged-import-chromium-control' })
  Assert-True ($chromiumRoute.Result.Code -eq 7 -and (Test-Path -LiteralPath $chromiumRoute.Marker) -and $chromiumReceipts.Count -eq 1 -and $chromiumReceipts[0].diagnostic.name -ceq 'staged-import-chromium-control' -and $chromiumReceipts[0].diagnostic.sha256 -ceq $scriptHash -and -not (Test-Path -LiteralPath $lockRoot)) 'staged-import Chromium declaration uses the admitted route and binds its named receipt'
  Remove-Item -LiteralPath $resultPath -Force
  Write-Output 'PASS staged-import-chromium-control admitted name=1 receipt=1 hash=1 released=1'

  $negatives=@(
    @{ Name='dotdot'; Override=@{ '-DiagnosticScriptPath'='.orchestrator/artifacts/../diagnostic-success.mjs' }; Text='diagnostic script must be a repository-relative standalone .mjs path' },
    @{ Name='absolute'; Override=@{ '-DiagnosticScriptPath'=$scriptPath }; Text='diagnostic script must be a repository-relative standalone .mjs path' },
    @{ Name='non-mjs'; Override=@{ '-DiagnosticScriptPath'='.orchestrator/artifacts/diagnostic-success.cjs' }; Text='diagnostic script must be a repository-relative standalone .mjs path' },
    @{ Name='infinity'; Override=@{ '-DiagnosticBudgetSeconds'='Infinity' }; Text='diagnostic budget must be finite and greater than zero' },
    @{ Name='negative'; Override=@{ '-DiagnosticBudgetSeconds'='-1' }; Text='diagnostic budget must be finite and greater than zero' },
    @{ Name='zero'; Override=@{ '-DiagnosticBudgetSeconds'='0' }; Text='diagnostic budget must be finite and greater than zero' },
    @{ Name='over-day'; Override=@{ '-DiagnosticBudgetSeconds'='86401' }; Text='diagnostic budget must be finite and greater than zero' },
    @{ Name='missing-budget'; Override=@{ '-DiagnosticBudgetSeconds'=$null }; Text='diagnostic budget is required' },
    @{ Name='above-max'; Override=@{ '-DiagnosticBudgetSeconds'='5' }; Text='diagnostic budget exceeds declared maximum' },
    @{ Name='hash-mismatch'; Override=@{ '-DiagnosticSha256'=('0'*64) }; Text='diagnostic SHA-256 does not match host declaration' },
    @{ Name='undeclared'; Override=@{ '-Diagnostic'='not-declared' }; Text='diagnostic name is not declared' },
    @{ Name='case-sensitive-name'; Override=@{ '-Diagnostic'='Worst13-no-fit' }; Text='diagnostic name is not declared' }
  )
  foreach($negative in $negatives) { Assert-Refused (Invoke-Diagnostic $negative.Override $negative.Name) $negative.Text }
  Write-Output 'PASS diagnostic negatives dotdot=1 absolute=1 non-mjs=1 Infinity=1 negative=1 zero=1 over-day=1 missing-budget=1 above-max=1 hash-mismatch=1 undeclared=1 case-sensitive=1 fresh-markers=12'

  $junctionTarget=Join-Path $root 'junction-target'; New-Item -ItemType Directory -Path $junctionTarget -Force | Out-Null; $junctionScript=Join-Path $junctionTarget 'diagnostic.mjs'; Set-Content -LiteralPath $junctionScript -Value "import fs from 'node:fs'; fs.writeFileSync(process.env.DIAGNOSTIC_MARKER, 'ran');"
  $junctionPath=Join-Path $worktree '.orchestrator\junction'; New-Item -ItemType Junction -Path $junctionPath -Target $junctionTarget | Out-Null; $junctionRelative='.orchestrator/junction/diagnostic.mjs'; $junctionHash=Get-Sha256 $junctionScript; Write-Declaration $junctionRelative $junctionHash
  Assert-Refused (Invoke-Diagnostic @{ '-DiagnosticScriptPath'=$junctionRelative; '-DiagnosticSha256'=$junctionHash } 'junction') 'diagnostic script path contains a reparse point'; Write-Output 'PASS diagnostic negative junction=1 fresh-marker=1'

  Write-Declaration $scriptRelative $scriptHash; $swapScript=Join-Path $root 'swap-diagnostic.ps1'; Set-Content -LiteralPath $swapScript -Value "Start-Sleep -Milliseconds 250; [IO.File]::WriteAllText('$scriptPath', 'import fs from ''node:fs''; fs.writeFileSync(process.env.DIAGNOSTIC_MARKER, ''swapped'');')"
  $swapProcess=Start-Process -FilePath (Join-Path $PSHOME 'pwsh.exe') -ArgumentList @('-NoProfile','-NonInteractive','-File',$swapScript) -WindowStyle Hidden -PassThru; $swapCase=Invoke-Diagnostic @{ '-TestDelayDiagnosticLaunchMilliseconds'='500' } 'hash-to-launch-swap'; $swapProcess.WaitForExit()
  Assert-Refused $swapCase 'declared diagnostic SHA-256 does not match the script'; Write-Output 'PASS diagnostic negative hash-to-launch-swap=1 fresh-marker=1'

  $trackedRelative='tracked-diagnostic-dependency.mjs'; $trackedPath=Join-Path $worktree $trackedRelative
  Set-Content -LiteralPath $trackedPath -Value "import fs from 'node:fs'; export const tracked = true; fs.writeFileSync(process.env.TRACKED_MARKER, 'tracked-ran');"
  Invoke-FixtureGit @('add','--',$trackedRelative) | Out-Null; Invoke-FixtureGit @('commit','-m','tracked diagnostic dependency') | Out-Null; $head=Invoke-FixtureGit @('rev-parse','HEAD')
  Set-Content -LiteralPath $scriptPath -Value "import '../../$trackedRelative'; import fs from 'node:fs'; fs.writeFileSync(process.env.DIAGNOSTIC_MARKER, 'tracked-entry-ran'); process.exitCode=7;"
  $scriptHash=Get-Sha256 $scriptPath; Write-Declaration $scriptRelative $scriptHash
  $trackedCase=Invoke-Diagnostic @{} 'tracked' @{ TRACKED_MARKER=(Join-Path $root 'tracked.marker') }
  $trackedReceipt=@(Get-ChildItem -LiteralPath $artifactRoot -Filter 'host-heavy-diagnostic-*.json' -File | Where-Object FullName -ne $receipt[0].FullName | Sort-Object LastWriteTimeUtc | Select-Object -Last 1)
  $trackedRecord=Get-Content -LiteralPath $trackedReceipt[0].FullName -Raw | ConvertFrom-Json -DateKind String
  $trackedModule=@($trackedRecord.modules | Where-Object path -like "*$trackedRelative")
  Assert-True ($trackedCase.Result.Code -eq 7 -and (Test-Path (Join-Path $root 'tracked.marker')) -and $trackedModule.Count -eq 1 -and $trackedModule[0].sha256 -ceq (Get-Sha256 $trackedPath)) 'tracked dependency is admitted and listed with loaded-byte hash in receipt'
  Write-Output 'PASS diagnostic dependency tracked=admitted receipt-listed=1 module-sha256=file-sha256=1'

  $ignoredRelative='.orchestrator/artifacts/node_modules/dep/index.mjs'; $ignoredPath=Join-Path $worktree ($ignoredRelative -replace '/','\'); $ignoredPackageRoot=Split-Path -Parent $ignoredPath
  New-Item -ItemType Directory -Path $ignoredPackageRoot -Force | Out-Null
  Set-Content -LiteralPath (Join-Path $ignoredPackageRoot 'package.json') -Value '{"type":"module","main":"index.mjs"}'
  Set-Content -LiteralPath $ignoredPath -Value "import fs from 'node:fs'; fs.writeFileSync(process.env.IGNORED_MARKER, 'ignored-ran');"
  Set-Content -LiteralPath $scriptPath -Value "import 'dep'; import fs from 'node:fs'; fs.writeFileSync(process.env.DIAGNOSTIC_MARKER, 'ignored-entry-ran');"
  $scriptHash=Get-Sha256 $scriptPath; Write-Declaration $scriptRelative $scriptHash
  $ignoredCase=Invoke-Diagnostic @{} 'ignored' @{ IGNORED_MARKER=(Join-Path $root 'ignored.marker') }
  $ignoredRefusal="heavy-admission: diagnostic module was not tracked at the bound head or under an admitted node_modules directory: $([IO.Path]::GetFullPath($ignoredPath))"
  $ignoredStderrLines=@($ignoredCase.Result.Stderr.Trim() -split '\r?\n')
  Assert-True ($ignoredCase.Result.Code -eq 73 -and $ignoredStderrLines[0] -ceq $ignoredRefusal -and -not (Test-Path (Join-Path $root 'ignored.marker'))) 'ignored nested dependency is refused before its body runs with exact refusal text'
  Write-Output 'PASS diagnostic dependency ignored-nested-node_modules=refused exit=73 exact-text=1 body=not-run'

  $childRefusalRelative='.orchestrator/artifacts/child-refusal.mjs'; $childRefusalPath=Join-Path $worktree ($childRefusalRelative -replace '/','\')
  Set-Content -LiteralPath $childRefusalPath -Value "import { spawn } from 'node:child_process'; const childEnv={...process.env}; delete childEnv.NODE_OPTIONS; spawn(process.execPath, ['-e', ''], { env: childEnv }); import fs from 'node:fs'; fs.writeFileSync(process.env.DIAGNOSTIC_MARKER, 'child-ran');"
  $scriptRelative=$childRefusalRelative; $scriptPath=$childRefusalPath; $scriptHash=Get-Sha256 $scriptPath; Write-Declaration $scriptRelative $scriptHash
  $childRefusal=Invoke-Diagnostic @{} 'child-refusal'
  Assert-True ($childRefusal.Result.Code -ne 0 -and $childRefusal.Result.Stderr -match [regex]::Escape('heavy-admission: diagnostic child process launch refused because NODE_OPTIONS lacks the diagnostic preload') -and -not (Test-Path $childRefusal.Marker)) 'child process without preload is refused'
  Write-Output 'PASS diagnostic child-without-preload=refused marker=absent'

  $workerRefusalRelative='.orchestrator/artifacts/worker-refusal.mjs'; $workerRefusalPath=Join-Path $worktree ($workerRefusalRelative -replace '/','\')
  Set-Content -LiteralPath $workerRefusalPath -Value "import { Worker } from 'node:worker_threads'; new Worker('setTimeout(() => {}, 10)', { eval: true }); import fs from 'node:fs'; fs.writeFileSync(process.env.DIAGNOSTIC_MARKER, 'worker-ran');"
  $scriptRelative=$workerRefusalRelative; $scriptPath=$workerRefusalPath; $scriptHash=Get-Sha256 $scriptPath; Write-Declaration $scriptRelative $scriptHash
  $workerRefusal=Invoke-Diagnostic @{} 'worker-refusal'
  Assert-True ($workerRefusal.Result.Code -ne 0 -and $workerRefusal.Result.Stderr -match [regex]::Escape('heavy-admission: diagnostic Worker launch refused') -and -not (Test-Path $workerRefusal.Marker)) 'Worker launch is refused'
  Write-Output 'PASS diagnostic worker=refused marker=absent'
  $callbackRelative='.orchestrator/artifacts/child-callback-refusal.mjs'; $callbackPath=Join-Path $worktree ($callbackRelative -replace '/','\')
  Set-Content -LiteralPath $callbackPath -Value "import { execFile } from 'node:child_process'; import fs from 'node:fs'; const childEnv={...process.env}; delete childEnv.NODE_OPTIONS; try { execFile(process.execPath, ['-e', ''], { env: childEnv }, () => {}); } catch (error) { process.stderr.write(String(error.message)); process.exit(73); } fs.writeFileSync(process.env.DIAGNOSTIC_MARKER, 'callback-ran');"
  $scriptRelative=$callbackRelative; $scriptPath=$callbackPath; $scriptHash=Get-Sha256 $scriptPath; Write-Declaration $scriptRelative $scriptHash
  $callbackRefusal=Invoke-Diagnostic @{} 'child-callback-refusal'
  Assert-True ($callbackRefusal.Result.Code -ne 0 -and $callbackRefusal.Result.Stderr -match [regex]::Escape('heavy-admission: diagnostic child process launch refused because NODE_OPTIONS lacks the diagnostic preload') -and -not (Test-Path $callbackRefusal.Marker)) 'execFile with options and callback reads the child env'
  $configDropRelative='.orchestrator/artifacts/child-config-drop.mjs'; $configDropPath=Join-Path $worktree ($configDropRelative -replace '/','\')
  Set-Content -LiteralPath $configDropPath -Value "import { spawnSync } from 'node:child_process'; import fs from 'node:fs'; const childEnv={...process.env}; delete childEnv.CHASE_SETS_HEAVY_ADMISSION_CONFIG; try { spawnSync(process.execPath, ['-e', ''], { env: childEnv }); } catch (error) { process.stderr.write(String(error.message)); process.exit(73); } fs.writeFileSync(process.env.DIAGNOSTIC_MARKER, 'config-drop-ran');"
  $scriptRelative=$configDropRelative; $scriptPath=$configDropPath; $scriptHash=Get-Sha256 $scriptPath; Write-Declaration $scriptRelative $scriptHash
  $configDrop=Invoke-Diagnostic @{} 'child-config-drop'
  Assert-True ($configDrop.Result.Code -ne 0 -and $configDrop.Result.Stderr -match [regex]::Escape('heavy-admission: diagnostic child process launch refused because the diagnostic admission configuration was not inherited') -and -not (Test-Path $configDrop.Marker)) 'child that keeps the preload but drops the admission configuration is refused'
  $smuggleRelative='.orchestrator/artifacts/child-node-options-smuggle.mjs'; $smugglePath=Join-Path $worktree ($smuggleRelative -replace '/','\')
  Set-Content -LiteralPath $smugglePath -Value "import { spawnSync, execSync } from 'node:child_process'; import fs from 'node:fs'; const refused=[]; const tryLaunch=(name, launch)=>{ try { launch(); } catch (error) { if (String(error.message).includes('NODE_OPTIONS lacks the diagnostic preload')) refused.push(name); } }; const keep=process.env.NODE_OPTIONS; tryLaunch('tab-prefix', () => spawnSync(process.execPath, ['-e', ''], { env: { ...process.env, NODE_OPTIONS: '--title=x\t' + keep } })); tryLaunch('appended', () => spawnSync(process.execPath, ['-e', ''], { env: { ...process.env, NODE_OPTIONS: keep + ' --title=x' } })); delete process.env.NODE_OPTIONS; tryLaunch('execSync-null', () => execSync('exit 0', null, { env: { ...process.env, NODE_OPTIONS: keep } })); process.env.NODE_OPTIONS=keep; let reads=0; const getterEnv={ ...process.env }; Object.defineProperty(getterEnv, 'NODE_OPTIONS', { enumerable: true, configurable: true, get: () => (reads++ === 0 ? keep : '') }); const pinned=spawnSync(process.execPath, ['-e', 'process.stdout.write(String(process.env.NODE_OPTIONS))'], { env: getterEnv, encoding: 'utf8' }); if (pinned.status === 0 && pinned.stdout === keep) refused.push('getter-pinned'); if (refused.length === 4) fs.writeFileSync(process.env.DIAGNOSTIC_MARKER, refused.join(','));"
  $scriptRelative=$smuggleRelative; $scriptPath=$smugglePath; $scriptHash=Get-Sha256 $scriptPath; Write-Declaration $scriptRelative $scriptHash
  $smuggle=Invoke-Diagnostic @{} 'child-node-options-smuggle'
  Assert-True ((Test-Path $smuggle.Marker) -and ([IO.File]::ReadAllText($smuggle.Marker) -ceq 'tab-prefix,appended,execSync-null,getter-pinned')) 'altered NODE_OPTIONS and execSync(cmd, null, opts) are refused; a getter env is pinned to the checked value'
  Write-Output 'PASS diagnostic child callback-options=refused config-drop=refused node-options-smuggle=refused env-getter=pinned'
  $prototypeRelative='.orchestrator/artifacts/child-env-prototype.mjs'; $prototypePath=Join-Path $worktree ($prototypeRelative -replace '/','\')
  Set-Content -LiteralPath $prototypePath -Value @'
import { spawnSync, execSync, spawn, ChildProcess } from 'node:child_process';
import fs from 'node:fs';
const keep = process.env.NODE_OPTIONS;
const probe = 'process.stdout.write(String(process.env.NODE_OPTIONS))';
const held = [];
// Each case passes only when the launch is refused or the child receives the checked value.
const check = (name, launch) => {
  try {
    const output = String(launch());
    if (output === keep) held.push(name);
  } catch (error) {
    if (String(error.message).includes('diagnostic child process launch refused')) held.push(name);
  }
};
// These must be refused outright: which duplicate entry a child sees depends on how the
// platform orders the environment block, so a launch that happens to deliver the value proves nothing.
const refused = (name, launch) => {
  try { launch(); } catch (error) { if (String(error.message).includes('diagnostic child process launch refused')) held.push(name); }
};
// keepFor(n) answers the checked value for n reads, then an empty string.
const keepFor = (allowed) => { let reads = 0; return () => (reads++ < allowed ? keep : ''); };
const run = (options) => spawnSync(process.execPath, ['-e', probe], { ...options, encoding: 'utf8' }).stdout;
const withoutOptions = () => spawnSync(process.execPath, ['-e', probe]).stdout;
const base = { ...process.env };
refused('equals-key', () => run({ env: { ...process.env, 'NODE_OPTIONS=--title=evil x': '1' } }));
refused('equals-key-empty', () => run({ env: { ...process.env, 'NODE_OPTIONS=': '' } }));
refused('case-duplicate', () => run({ env: { ...process.env, node_options: '' } }));
delete process.env.NODE_OPTIONS;
// Node reads options only from index 1 or 2; an object at 3 must not stand in for them.
refused('ignored-slot', () => spawnSync(process.execPath, ['-e', probe], undefined, { env: { ...process.env, NODE_OPTIONS: keep } }).stdout);
process.env.NODE_OPTIONS = keep;
refused('process-binding', () => { process.binding('spawn_sync'); return ''; });
refused('process-binding-wrap', () => { process.binding('process_wrap'); return ''; });
// Below child_process: the exported class and a live child's handle reach the native spawn directly.
const strippedPairs = Object.entries(process.env).filter(([key]) => key !== 'NODE_OPTIONS').map(([key, value]) => key + '=' + value);
refused('childprocess-class', () => new ChildProcess().spawn({ file: process.execPath, args: [process.execPath, '-e', ''], envPairs: strippedPairs, stdio: 'ignore' }));
const legitimate = spawn(process.execPath, ['-e', ''], { stdio: 'ignore' });
refused('handle-reuse', () => { const handle = new legitimate._handle.constructor(); handle.onexit = () => {}; return handle.spawn({ file: process.execPath, args: [process.execPath, '-e', ''], envPairs: strippedPairs, stdio: [{ type: 'ignore' }, { type: 'ignore' }, { type: 'ignore' }] }); });
delete base.NODE_OPTIONS;
const ownProtoKey = { ...base };
Object.defineProperty(ownProtoKey, '__proto__', { enumerable: true, configurable: true, writable: true, value: Object.defineProperty({}, 'NODE_OPTIONS', { enumerable: true, get: keepFor(1) }) });
check('own-proto-key', () => run({ env: ownProtoKey }));
Object.defineProperty(Object.prototype, 'NODE_OPTIONS', { enumerable: true, configurable: true, get: keepFor(2), set() {} });
check('inherited-setter', () => run({ env: { ...base } }));
delete Object.prototype.NODE_OPTIONS;
delete process.env.NODE_OPTIONS;
Object.defineProperty(Object.prototype, 'NODE_OPTIONS', { enumerable: true, configurable: true, get: keepFor(1) });
check('process-env-inherited', withoutOptions);
delete Object.prototype.NODE_OPTIONS;
process.env.NODE_OPTIONS = keep;
Object.defineProperty(Object.prototype, 'env', { configurable: true, get: () => ({ ...process.env, NODE_OPTIONS: '' }) });
check('inherited-options-env', withoutOptions);
check('inherited-options-env-exec', () => execSync(JSON.stringify(process.execPath) + ' -e ' + JSON.stringify(probe), { encoding: 'utf8' }));
delete Object.prototype.env;
fs.writeFileSync(process.env.DIAGNOSTIC_MARKER, held.join(','));
'@
  $scriptRelative=$prototypeRelative; $scriptPath=$prototypePath; $scriptHash=Get-Sha256 $scriptPath; Write-Declaration $scriptRelative $scriptHash 2
  $prototypeCase=Invoke-Diagnostic @{} 'child-env-prototype'
  $prototypeHeld=if (Test-Path $prototypeCase.Marker) { [IO.File]::ReadAllText($prototypeCase.Marker) } else { '<no marker>' }
  Assert-True ($prototypeHeld -ceq 'equals-key,equals-key-empty,case-duplicate,ignored-slot,process-binding,process-binding-wrap,childprocess-class,handle-reuse,own-proto-key,inherited-setter,process-env-inherited,inherited-options-env,inherited-options-env-exec') "prototype tricks cannot change the child env after the check (held: $prototypeHeld; exit: $($prototypeCase.Result.Code); stderr: $($prototypeCase.Result.Stderr))"
  Write-Output 'PASS diagnostic child-env-prototype=pinned-or-refused'

  $manifestRemovalRelative='.orchestrator/artifacts/manifest-removal.mjs'; $manifestRemovalPath=Join-Path $worktree ($manifestRemovalRelative -replace '/','\')
  Set-Content -LiteralPath $manifestRemovalPath -Value @'
import fs from 'node:fs';
const configuration = JSON.parse(Buffer.from(process.env.CHASE_SETS_HEAVY_ADMISSION_CONFIG, 'base64').toString('utf8'));
fs.rmSync(`${configuration.diagnostic.moduleManifestPath}-${process.pid}.json`, { force: true });
'@
  $scriptRelative=$manifestRemovalRelative; $scriptPath=$manifestRemovalPath; $scriptHash=Get-Sha256 $scriptPath; Write-Declaration $scriptRelative $scriptHash
  $missingManifest=Invoke-Diagnostic @{} 'missing-manifest'
  Assert-Refused $missingManifest 'diagnostic module manifest is missing'
  Write-Output 'PASS diagnostic manifest=missing exit=73 no-success=1'

  $manifestEntryRelative='.orchestrator/artifacts/manifest-no-entry.mjs'; $manifestEntryPath=Join-Path $worktree ($manifestEntryRelative -replace '/','\')
  Set-Content -LiteralPath $manifestEntryPath -Value @'
import fs from 'node:fs';
const configuration = JSON.parse(Buffer.from(process.env.CHASE_SETS_HEAVY_ADMISSION_CONFIG, 'base64').toString('utf8'));
fs.writeFileSync(`${configuration.diagnostic.moduleManifestPath}-${process.pid}.json`, JSON.stringify({ schema: 'host-heavy-diagnostic-modules/v1', modules: [] }));
'@
  $scriptRelative=$manifestEntryRelative; $scriptPath=$manifestEntryPath; $scriptHash=Get-Sha256 $scriptPath; Write-Declaration $scriptRelative $scriptHash
  $manifestWithoutEntry=Invoke-Diagnostic @{} 'manifest-without-entry'
  Assert-Refused $manifestWithoutEntry 'diagnostic module manifest did not record the declared entry'
  Write-Output 'PASS diagnostic manifest=without-entry exit=73 no-success=1'

  $timeoutRelative='.orchestrator/artifacts/diagnostic-timeout.mjs'; $timeoutPath=Join-Path $worktree ($timeoutRelative -replace '/','\'); Set-Content -LiteralPath $timeoutPath -Value @'
import fs from 'node:fs';
import { spawn } from 'node:child_process';
fs.writeFileSync(process.env.DIAGNOSTIC_ROOT_PID, String(process.pid));
const blockedChild = `
  const fs = require('node:fs');
  fs.writeFileSync(process.env.DIAGNOSTIC_CHILD_PID, String(process.pid));
  fs.writeFileSync(process.env.DIAGNOSTIC_BARRIER, 'barrier-reached');
  const hold = setInterval(() => { if (fs.existsSync(process.env.DIAGNOSTIC_RELEASE)) clearInterval(hold); }, 25);
`;
if (process.env.DIAGNOSTIC_LINGERING_DESCENDANT === '1') {
  const child = spawn(process.execPath, ['-e', blockedChild], { detached: true, windowsHide: true, stdio: 'ignore', env: { ...process.env } });
  child.unref();
  while (!fs.existsSync(process.env.DIAGNOSTIC_ROOT_RELEASE)) await new Promise((resolve) => setTimeout(resolve, 25));
  process.exit(0);
} else {
  fs.writeFileSync(process.env.DIAGNOSTIC_CHILD_PID, String(process.pid));
  fs.writeFileSync(process.env.DIAGNOSTIC_BARRIER, 'barrier-reached');
  while (!fs.existsSync(process.env.DIAGNOSTIC_RELEASE)) await new Promise((resolve) => setTimeout(resolve, 25));
}
'@
  $scriptRelative=$timeoutRelative; $scriptPath=$timeoutPath; $scriptHash=Get-Sha256 $scriptPath; Write-Declaration $scriptRelative $scriptHash 900
  Test-DiagnosticStaleIdentityTimeout
  foreach ($lingering in @($false, $true)) {
    $caseName=if ($lingering) { 'timeout-lingering-descendant' } else { 'timeout-root' }
    $timeoutRun=New-BarrierDiagnostic $testGuard $caseName -LingeringDescendant:$lingering
    try {
      Wait-BarrierDiagnostic $timeoutRun
      if ($lingering) {
        $nativeRoot=Get-Process -Id ([int]([IO.File]::ReadAllText($timeoutRun.RootPidPath))) -ErrorAction Stop
        [void]$nativeRoot.Handle; $timeoutRun.Processes.Add($nativeRoot)
        New-Item -ItemType File -Path $timeoutRun.RootRelease -Force | Out-Null
        $rootExited=$nativeRoot.WaitForExit(15000)
        Assert-True ($rootExited -and $nativeRoot.ExitCode -eq 0 -and -not $timeoutRun.Processes[0].HasExited) "lingering-descendant-ready: native root exits 0 while its barrier-blocked descendant remains alive (rootExited=$rootExited nativeExit=$($nativeRoot.ExitCode) descendantExited=$($timeoutRun.Processes[0].HasExited))"
        Write-Output 'PASS lingering-descendant-ready root-exit=0 descendant-live=1 barrier-held=1'
      }
      Set-DiagnosticClock $timeoutRun.Clock ([DateTimeOffset]::UtcNow.AddSeconds(901))
      $outcome=Wait-DiagnosticBudgetOutcome $timeoutRun
      Assert-DiagnosticTimeoutExit $outcome "$caseName-must-exit-124"
      $timeoutReceipt=@(Get-ChildItem -LiteralPath $artifactRoot -Filter 'host-heavy-diagnostic-*.json' -File | Where-Object { $_.FullName -notin $timeoutRun.ReceiptsBefore })
      Assert-True ($timeoutReceipt.Count -eq 1) 'named timeout assertion finds exactly one new durable staged-import receipt'
      $timeoutRecord=Get-Content -LiteralPath $timeoutReceipt[0].FullName -Raw | ConvertFrom-Json -DateKind String
      Assert-True ($timeoutRecord.diagnostic.name -ceq 'staged-import-chromium-control' -and $timeoutRecord.diagnostic.budgetSeconds -eq 900 -and $timeoutRecord.timedOut -eq $true -and $timeoutRecord.exit -eq 124) "named timeout receipt assertion records timedOut and exit (name=$($timeoutRecord.diagnostic.name) timedOut=$($timeoutRecord.timedOut) exit=$($timeoutRecord.exit) nativeExit=$($timeoutRecord.nativeExit))"
      if ($lingering) { Assert-True ($timeoutRecord.nativeExit -eq 0) "lingering-descendant-native-exit: receipt preserves nativeExit=0 (actual=$($timeoutRecord.nativeExit))" }
      foreach ($process in $timeoutRun.Processes) { Assert-True $process.HasExited "named timeout cleanup assertion leaves no surviving process (pid=$($process.Id))" }
      Assert-True (-not (Test-Path -LiteralPath $lockRoot)) 'named timeout cleanup assertion releases admission lock'
      New-Item -ItemType File -Path $timeoutRun.Release -Force | Out-Null
      foreach ($process in $timeoutRun.Processes) { Assert-True $process.HasExited "named timeout barrier-release assertion leaves no surviving process (pid=$($process.Id))" }
      Write-Output "PASS diagnostic $caseName real-route=1 staged-name=1 budget=900 timedOut=1 receipt=1 exit=124 nativeExit=$($timeoutRecord.nativeExit) child-dead=1 lock-released=1 barrier-released-after=1"
    } finally { Close-BarrierDiagnostic $timeoutRun }
  }

  $mutantGuard=New-TestOnlyDiagnosticGuard 'timeout-mutant' -DisableTimeout
  Write-Output "PASS mutant fixture verifier clock substitution-count=$script:diagnosticClockSubstitutionCount"
  $mutantRun=New-BarrierDiagnostic $mutantGuard 'timeout-mutant'
  try {
    Wait-BarrierDiagnostic $mutantRun
    Set-DiagnosticClock $mutantRun.Clock ([DateTimeOffset]::UtcNow.AddSeconds(901))
    $outcome=Wait-DiagnosticBudgetOutcome $mutantRun
    Assert-True ($outcome.SurvivedBudget -and -not $outcome.Completed -and -not $mutantRun.Processes[0].HasExited -and -not (Test-Path -LiteralPath $mutantRun.Release)) 'mutant-past-budget: launched native child must remain alive behind the barrier across two expired-clock reads; setup errors cannot kill this mutant'
    $mutantFailedAssertion=$false
    try { Assert-DiagnosticTimeoutExit $outcome 'mutant-timeout-must-exit-124' } catch {
      if (-not $_.Exception.Message.StartsWith('ASSERTION FAILED: mutant-timeout-must-exit-124:')) { throw }
      $mutantFailedAssertion=$true
      Write-Output $_.Exception.Message
    }
    Assert-True $mutantFailedAssertion 'named timeout-enforcement mutant must fail the named exit-124 assertion'
    New-Item -ItemType File -Path $mutantRun.Release -Force | Out-Null
    Assert-True ($mutantRun.Started.Process.WaitForExit(15000)) 'mutant released barrier must let the real verifier finish normally'
    $mutantResult=Complete-TestChild $mutantRun.Started
    Assert-True ($mutantResult.Code -eq 0 -and $mutantRun.Processes[0].HasExited -and -not (Test-Path -LiteralPath $lockRoot)) "mutant setup and normal completion must succeed (exit=$($mutantResult.Code) stderr=$($mutantResult.Stderr))"
    Write-Output 'KILLED mutant diagnostic-timeout-enforcement at assertion=mutant-timeout-must-exit-124 launched=1 child-live-past-budget=1 expired-clock-reads=2 released-exit=0'
  } finally { Close-BarrierDiagnostic $mutantRun }

  # The Vitest route is a closed declaration, not a free-form command seam.
  # Keep these controls after the fixture has an exact tracked canonical entry
  # so every refusal exercises declaration admission itself.
  $canonicalEntry=Join-Path $worktree 'scripts/canonical-record.test.mjs'
  New-Item -ItemType Directory -Path (Split-Path -Parent $canonicalEntry) -Force | Out-Null
  Set-Content -LiteralPath $canonicalEntry -Value "import fs from 'node:fs'; fs.writeFileSync(process.env.DIAGNOSTIC_MARKER, 'canonical-body-ran');"
  Invoke-FixtureGit @('add','--','scripts/canonical-record.test.mjs') | Out-Null
  Invoke-FixtureGit @('commit','-m','canonical vitest entry') | Out-Null
  $head=Invoke-FixtureGit @('rev-parse','HEAD')
  $canonicalReleasePath=Join-Path $PSScriptRoot 'diagnostic-declarations.json'
  $canonicalDeclarationMutants=@(
    @{ Name='canonical-test-path'; Expected='vitest-command entry path is not the canonical-record test'; Mutate={ param($d) $d.diagnostics.'canonical-vitest-residual-v1'.path='scripts/not-canonical-record.test.mjs' } },
    @{ Name='canonical-config-path'; Expected='vitest-command declaration does not pin the canonical command'; Mutate={ param($d) $d.diagnostics.'canonical-vitest-residual-v1'.command.arguments[4]='./not-vitest.scripts.config.mjs' } },
    @{ Name='canonical-executable'; Expected='vitest-command declaration does not pin the canonical command'; Mutate={ param($d) $d.diagnostics.'canonical-vitest-residual-v1'.command.executable='npm' } },
    @{ Name='canonical-extra-argument'; Expected='vitest-command declaration does not pin the canonical command'; Mutate={ param($d) $d.diagnostics.'canonical-vitest-residual-v1'.command.arguments=@($d.diagnostics.'canonical-vitest-residual-v1'.command.arguments) + @('--extra') } },
    @{ Name='canonical-missing-argument'; Expected='vitest-command declaration does not pin the canonical command'; Mutate={ param($d) $d.diagnostics.'canonical-vitest-residual-v1'.command.arguments=@($d.diagnostics.'canonical-vitest-residual-v1'.command.arguments)[0..7] } },
    @{ Name='canonical-argument-order'; Expected='vitest-command declaration does not pin the canonical command'; Mutate={ param($d) $a=$d.diagnostics.'canonical-vitest-residual-v1'.command.arguments; $tmp=$a[4]; $a[4]=$a[5]; $a[5]=$tmp } },
    @{ Name='canonical-test-file-value'; Expected='vitest-command declaration does not pin the canonical command'; Mutate={ param($d) $d.diagnostics.'canonical-vitest-residual-v1'.command.arguments[5]='scripts/not-canonical-record.test.mjs' } },
    @{ Name='canonical-max-workers'; Expected='vitest-command declaration does not pin the canonical command'; Mutate={ param($d) $d.diagnostics.'canonical-vitest-residual-v1'.command.arguments[6]='--maxWorkers=2' } },
    @{ Name='canonical-file-parallelism'; Expected='vitest-command declaration does not pin the canonical command'; Mutate={ param($d) $d.diagnostics.'canonical-vitest-residual-v1'.command.arguments[7]='--fileParallelism=true' } },
    @{ Name='canonical-silent'; Expected='vitest-command declaration does not pin the canonical command'; Mutate={ param($d) $d.diagnostics.'canonical-vitest-residual-v1'.command.arguments[8]='--silent=true' } }
  )
  foreach ($mutant in $canonicalDeclarationMutants) {
    $declaration=Get-Content -LiteralPath $canonicalReleasePath -Raw | ConvertFrom-Json
    & $mutant.Mutate $declaration
    [IO.File]::WriteAllText($declarationPath, ($declaration | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
    $case=Invoke-CanonicalDiagnostic $mutant.Name
    Assert-CanonicalDeclarationRefused $case $mutant.Expected $case.ReceiptsBefore
    Write-Output "KILLED mutant $($mutant.Name) at assertion=canonical-command-pinned launched=0 exit=73 body-side-effect=0 receipt=0"
  }
  foreach ($mutant in @(
    @{ Name='canonical-caller-supplied-path'; Override=@{ '-DiagnosticScriptPath'='scripts/canonical-record.test.mjs' } },
    @{ Name='canonical-caller-supplied-hash'; Override=@{ '-DiagnosticSha256'=('0'*64) } }
  )) {
    $declaration=Get-Content -LiteralPath $canonicalReleasePath -Raw | ConvertFrom-Json
    [IO.File]::WriteAllText($declarationPath, ($declaration | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
    $case=Invoke-CanonicalDiagnostic $mutant.Name $mutant.Override
    Assert-CanonicalDeclarationRefused $case 'vitest-command diagnostics do not accept a standalone script hash' $case.ReceiptsBefore
    Write-Output "KILLED mutant $($mutant.Name) at assertion=caller-input-rejected launched=0 exit=73 body-side-effect=0 receipt=0"
  }

  # A small Node-hosted pnpm fixture reaches the real diagnostic launch and
  # preload path without depending on this controller checkout's pnpm install.
  $nodePath=(Get-Command node -ErrorAction Stop).Source
  $fakePnpmScript=Join-Path $worktree '.orchestrator\canonical-pnpm\node_modules\pnpm\bin\pnpm.cjs'
  New-Item -ItemType Directory -Path (Split-Path -Parent $fakePnpmScript) -Force | Out-Null
  Set-Content -LiteralPath $fakePnpmScript -Value @'
const { pathToFileURL } = require('node:url');
(async () => { await import(pathToFileURL(process.env.CANONICAL_ENTRY).href); })().catch((error) => { console.error(error); process.exitCode = 73; });
'@
  $canonicalGuard=New-TestOnlyDiagnosticGuard 'canonical-vitest-synthetic'
  $canonicalGuardText=[IO.File]::ReadAllText($canonicalGuard)
  $pnpmResolveAnchor='if (-not $hostNode -or -not $pnpmScript) {'
  $pnpmResolveReplacement='$hostNode = $env:CANONICAL_TEST_NODE' + [Environment]::NewLine + '$pnpmScript = $env:CANONICAL_TEST_PNPM' + [Environment]::NewLine + $pnpmResolveAnchor
  Assert-True (([regex]::Matches($canonicalGuardText,[regex]::Escape($pnpmResolveAnchor))).Count -eq 1) 'canonical synthetic fixture replaces only host Node/pnpm resolution'
  [IO.File]::WriteAllText($canonicalGuard,$canonicalGuardText.Replace($pnpmResolveAnchor,$pnpmResolveReplacement),[Text.UTF8Encoding]::new($false))
  $declaration=Get-Content -LiteralPath $canonicalReleasePath -Raw | ConvertFrom-Json
  [IO.File]::WriteAllText($declarationPath, ($declaration | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
  $positive=Invoke-CanonicalDiagnostic 'canonical-vitest-positive' @{} @{
    CANONICAL_TEST_NODE=$nodePath; CANONICAL_TEST_PNPM=$fakePnpmScript; CANONICAL_ENTRY=$canonicalEntry
  } $canonicalGuard
  $positiveReceipts=@(Get-DiagnosticReceiptPaths | Where-Object { $_ -notin $positive.ReceiptsBefore })
  Assert-True ($positive.Result.Code -eq 0 -and (Test-Path -LiteralPath $positive.Marker) -and @($positiveReceipts).Count -eq 1) "canonical Vitest synthetic route reaches the real launch path (exit=$($positive.Result.Code) marker=$(Test-Path -LiteralPath $positive.Marker) receipts=$(@($positiveReceipts).Count) stderr=$($positive.Result.Stderr))"
  $positiveRecord=Get-Content -LiteralPath $positiveReceipts[0] -Raw | ConvertFrom-Json
  Assert-True ($positiveRecord.command.executable -ceq 'pnpm' -and $positiveRecord.command.arguments.Count -eq 9 -and
    [IO.Path]::GetFileName([string]$positiveRecord.command.launchExecutable) -ieq 'node.exe' -and
    [IO.Path]::GetFileName([string]$positiveRecord.command.launchArguments[0]) -ieq 'pnpm.cjs' -and
    $positiveRecord.exit -eq 0 -and $positiveRecord.nativeExit -eq 0 -and -not (Test-Path -LiteralPath $lockRoot)) 'canonical Vitest synthetic receipt binds user command, Node-hosted pnpm launch and native success'
  Write-Output 'PASS canonical-vitest synthetic-route=1 launch-path=1 receipt-command=1 native-exit=0'

  $unauthorizedPath=Join-Path $worktree '.orchestrator\canonical-unauthorized.mjs'
  Set-Content -LiteralPath $unauthorizedPath -Value "import fs from 'node:fs'; fs.writeFileSync(process.env.DIAGNOSTIC_UNAUTHORIZED_MARKER, 'unauthorized-body-ran');"
  Set-Content -LiteralPath $canonicalEntry -Value @'
import { pathToFileURL } from 'node:url';
await import(pathToFileURL(process.env.CANONICAL_UNAUTHORIZED).href);
import fs from 'node:fs';
fs.writeFileSync(process.env.DIAGNOSTIC_MARKER, 'canonical-body-ran');
'@
  Invoke-FixtureGit @('add','--','scripts/canonical-record.test.mjs') | Out-Null
  Invoke-FixtureGit @('commit','-m','canonical vitest unauthorized import fixture') | Out-Null
  $head=Invoke-FixtureGit @('rev-parse','HEAD')
  $policyControl=Invoke-CanonicalDiagnostic 'canonical-vitest-preload-control' @{} @{
    CANONICAL_TEST_NODE=$nodePath; CANONICAL_TEST_PNPM=$fakePnpmScript; CANONICAL_ENTRY=$canonicalEntry; CANONICAL_UNAUTHORIZED=$unauthorizedPath
  } $canonicalGuard
  Assert-CanonicalPreloadRefused $policyControl 'diagnostic module was not tracked at the bound head or under an admitted node_modules directory:'
  Write-Output 'PASS canonical-vitest preload-root-control exit=73 unauthorized-body=0 lock-released=1'
  $rootMutantGuard=New-TestOnlyDiagnosticGuard 'canonical-vitest-root-mutant'
  $rootMutantPreload=Join-Path (Split-Path -Parent $rootMutantGuard) 'heavy-admission-preload.cjs'
  $rootMutantText=[IO.File]::ReadAllText($rootMutantPreload)
  $rootAnchor='const insideAllowedRoot = (candidate) => allowedRoots.some((root) => samePath(root, candidate) || inside(root, candidate));'
  Assert-True (([regex]::Matches($rootMutantText,[regex]::Escape($rootAnchor))).Count -eq 1) 'canonical pnpm-root mutant target occurs exactly once'
  [IO.File]::WriteAllText($rootMutantPreload,$rootMutantText.Replace($rootAnchor,'const insideAllowedRoot = (candidate) => true;'),[Text.UTF8Encoding]::new($false))
  $rootMutant=Invoke-CanonicalDiagnostic 'canonical-vitest-pnpm-root-mutant' @{} @{
    CANONICAL_TEST_NODE=$nodePath; CANONICAL_TEST_PNPM=$fakePnpmScript; CANONICAL_ENTRY=$canonicalEntry; CANONICAL_UNAUTHORIZED=$unauthorizedPath
  } $rootMutantGuard
  $rootMutantFailed=$false
  try { Assert-CanonicalPreloadRefused $rootMutant 'diagnostic module was not tracked at the bound head or under an admitted node_modules directory:' } catch {
    if (-not $_.Exception.Message.StartsWith('ASSERTION FAILED: canonical preload refusal uses exit 73:')) { throw }
    $rootMutantFailed=$true
  }
  Assert-True $rootMutantFailed 'pnpm-root widening mutant must fail the unauthorized-module refusal assertion'
  Write-Output 'KILLED mutant allow-worktree-as-pnpm-root at assertion=canonical-preload-authorization launched=1 body-side-effect=1'

  # The transformed-entry exception is Vitest-only. A standalone entry that
  # reloads itself with changed bytes must still be refused before its marker.
  $transformedRelative='.orchestrator/artifacts/canonical-transformed.mjs'
  $transformedPath=Join-Path $worktree ($transformedRelative -replace '/','\')
  Set-Content -LiteralPath $transformedPath -Value @'
import fs from 'node:fs';
const transformed = "import fs from 'node:fs'; fs.writeFileSync(process.env.DIAGNOSTIC_MARKER, 'transformed-body-ran');";
fs.writeFileSync(new URL('./canonical-transformed.mjs', import.meta.url), transformed);
await import('./canonical-transformed.mjs?transformed');
'@
  $scriptRelative=$transformedRelative; $scriptPath=$transformedPath; $scriptHash=Get-Sha256 $scriptPath; Write-Declaration $scriptRelative $scriptHash 600
  $transformedControl=Invoke-Diagnostic @{} 'canonical-vitest-transformed-entry-control'
  Assert-CanonicalPreloadRefused $transformedControl 'declared diagnostic entry changed before evaluation'
  Write-Output 'PASS canonical-vitest transformed-entry-control exit=73 transformed-body=0 lock-released=1'
  Set-Content -LiteralPath $transformedPath -Value @'
import fs from 'node:fs';
const transformed = "import fs from 'node:fs'; fs.writeFileSync(process.env.DIAGNOSTIC_MARKER, 'transformed-body-ran');";
fs.writeFileSync(new URL('./canonical-transformed.mjs', import.meta.url), transformed);
await import('./canonical-transformed.mjs?transformed');
'@
  $transformedMutantGuard=New-TestOnlyDiagnosticGuard 'canonical-vitest-transformed-mutant'
  $transformedMutantText=[IO.File]::ReadAllText((Join-Path (Split-Path -Parent $transformedMutantGuard) 'heavy-admission-preload.cjs'))
  $transformedAnchor='const allowTransformedEntry = diagnostic.kind === "vitest-command";'
  Assert-True (([regex]::Matches($transformedMutantText,[regex]::Escape($transformedAnchor))).Count -eq 1) 'canonical transformed-entry mutant target occurs exactly once'
  $transformedRecordAnchor='if (recorded && sha256 !== recorded.sha256) {'
  Assert-True (([regex]::Matches($transformedMutantText,[regex]::Escape($transformedRecordAnchor))).Count -eq 1) 'canonical transformed-entry recorded-digest mutant target occurs exactly once'
  $transformedMutantText=$transformedMutantText.Replace($transformedAnchor,'const allowTransformedEntry = true;').Replace($transformedRecordAnchor,'if (recorded && sha256 !== recorded.sha256 && !allowTransformedEntry) {')
  [IO.File]::WriteAllText((Join-Path (Split-Path -Parent $transformedMutantGuard) 'heavy-admission-preload.cjs'),$transformedMutantText,[Text.UTF8Encoding]::new($false))
  $transformedMutant=Invoke-Diagnostic @{} 'canonical-vitest-transformed-entry-mutant' @{} 'worst13-no-fit' $transformedMutantGuard
  $transformedMutantFailed=$false
  try { Assert-CanonicalPreloadRefused $transformedMutant 'declared diagnostic entry changed before evaluation' } catch {
    if (-not $_.Exception.Message.StartsWith('ASSERTION FAILED: canonical preload refusal uses exit 73:')) { throw }
    $transformedMutantFailed=$true
  }
  Assert-True $transformedMutantFailed 'transformed-entry widening mutant must fail the standalone entry refusal assertion'
  Write-Output 'KILLED mutant allow-standalone-transformed-entry at assertion=canonical-preload-authorization launched=1 body-side-effect=1'

  $outside=Invoke-Diagnostic @{ '-ContainerRoot'=(Get-Location).Path } 'outside-container'
  Assert-Refused $outside 'arbitrary commands are fixture-only; use invoke-heavy-verifier.ps1 -Gate or -WorkspaceTest'
  Write-Output 'PASS diagnostic negative outside-container=1 fresh-marker=1'

  $safeRelative='.orchestrator/unsafe-receipt.mjs'; $safePath=Join-Path $worktree ($safeRelative -replace '/','\'); Set-Content -LiteralPath $safePath -Value "import fs from 'node:fs'; fs.writeFileSync(process.env.DIAGNOSTIC_MARKER, 'unsafe-body-ran');"; $safeHash=Get-Sha256 $safePath; Write-Declaration $safeRelative $safeHash
  Remove-Item -LiteralPath $artifactRoot -Recurse -Force; Set-Content -LiteralPath $artifactRoot -Value 'not-a-directory'
  $unsafe=Invoke-Diagnostic @{ '-DiagnosticScriptPath'=$safeRelative; '-DiagnosticSha256'=$safeHash } 'unsafe-receipt'
  Assert-True ($unsafe.Result.Code -eq 73 -and $unsafe.Result.Stderr.Trim() -ceq 'heavy-verifier: receipt directory is unsafe' -and -not (Test-Path (Join-Path $root 'unsafe-receipt.marker'))) 'unsafe receipt path is refused with exact text and diagnostic body is not run'
  Write-Output 'PASS diagnostic negative unsafe-receipt=1 exact-text=1 no-success=1'
} finally { if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue } }
