$ErrorActionPreference = 'Stop'
$errors = $null
$test = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'invoke-heavy-verifier.test.ps1'), [ref]$null, [ref]$errors)
if ($errors.Count) { throw 'ordinary verifier test must parse' }
$guardSource = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'invoke-heavy-verifier.ps1'))
$verifier = [Management.Automation.Language.Parser]::ParseInput($guardSource, [ref]$null, [ref]$errors)
if ($errors.Count) { throw 'actual verifier must parse' }
function Find-Definition($Ast, [string]$Name) {
  $found = @($Ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $Name }, $true))
  if ($found.Count -ne 1) { throw "expected one actual $Name definition" }
  return $found[0]
}
function Get-Runner($Function, [string]$Variable) {
  $writes = @($Function.FindAll({ param($node)
    $node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $node.Member.Value -ceq 'WriteAllText' -and
      $node.Arguments.Count -eq 2 -and $node.Arguments[0].Extent.Text -ceq $Variable
  }, $true))
  if ($writes.Count -ne 1) { throw "expected one actual $Variable runner definition" }
  return $writes[0].Arguments[1].SafeGetValue()
}
$runners = @{
  host = Get-Runner (Find-Definition $test 'Test-ControllerHostHeavyVerifier') '$runner'
  fixture = Get-Runner (Find-Definition $test 'Test-ControllerFixtureEquivalence') '$fixtureRunner'
}
function Assert-True($Condition, [string]$Message) { if (-not $Condition) { throw "ASSERTION FAILED: $Message" } }
. ([scriptblock]::Create((Find-Definition $test 'Assert-PrecursorAdmissionSurface').Extent.Text))
Assert-PrecursorAdmissionSurface $guardSource
$replayAttribute = '  [Parameter(ParameterSetName = "ManifestReplay", DontShow)]'
foreach ($replacement in @('', ($replayAttribute + "`n" + '  [Parameter(ParameterSetName = "ControllerPrecursor", DontShow)]'))) {
  $changed = $guardSource.Replace($replayAttribute, $replacement)
  $refused = $false
  try { Assert-PrecursorAdmissionSurface $changed } catch { $refused = $true }
  if (-not $refused) { throw 'missing replay or opened precursor command metadata mutant must refuse' }
}
$validation = @($verifier.EndBlock.Statements | Where-Object {
  $_ -is [Management.Automation.Language.IfStatementAst] -and $_.Clauses[0].Item1.Extent.Text -ceq '-not $isManifestReplay'
})
if ($validation.Count -ne 1) { throw 'expected one actual non-replay closed-value validator' }
$temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/')
$root = Join-Path $temp ('closed-route-binding-' + [guid]::NewGuid().ToString('N'))
$guard = Join-Path $root 'inert-guard.ps1'
$body = Join-Path $root 'body.txt'
$inputPath = Join-Path $root 'input.json'
try {
  [void][IO.Directory]::CreateDirectory($root)
  # Only actual metadata and the early scalar validator. No runtime function,
  # admission, Git, process census, native helper, Job or signal is copied.
  $prefix = $verifier.ParamBlock.Extent.Text + "`n" + '$isManifestReplay=$PSBoundParameters.ContainsKey(''ManifestReplay'')' + "`n" + $validation[0].Extent.Text
  [IO.File]::WriteAllText($guard, $prefix + "`n[IO.File]::WriteAllText('$($body.Replace("'", "''"))','inert body'); exit 0")
  $cases = @(
    @{ Name = 'fixture-positive'; Values = @{ ControllerFixtureEquivalence = $true; ControllerFixtureEvidenceDirectory = $root }; Exit = 0; Body = $true },
    @{ Name = 'host-positive'; Values = @{ ControllerHostHeavyVerifier = $true }; Exit = 0; Body = $true },
    @{ Name = 'precursor-positive'; Values = @{ ControllerPrecursor = 'fail-closed-guard-evidence'; ControllerPrecursorArtifactPath = 'inert.json' }; Exit = 0; Body = $true },
    @{ Name = 'fixture-command'; Values = @{ ControllerFixtureEquivalence = $true; ControllerFixtureEvidenceDirectory = $root; CommandPath = 'inert' }; Exit = 1; Binding = $true },
    @{ Name = 'fixture-mixed'; Values = @{ ControllerFixtureEquivalence = $true; ControllerFixtureEvidenceDirectory = $root; Gate = 'verify:static' }; Exit = 1; Binding = $true },
    @{ Name = 'host-command'; Values = @{ ControllerHostHeavyVerifier = $true; CommandPath = 'inert' }; Exit = 1; Binding = $true },
    @{ Name = 'precursor-command'; Values = @{ ControllerPrecursor = 'fail-closed-guard-evidence'; ControllerPrecursorArtifactPath = 'inert.json'; CommandPath = 'inert' }; Exit = 1; Binding = $true },
    @{ Name = 'unsupported-gate'; Values = @{ Gate = 'not-a-heavy-gate' }; Exit = 1; ClosedValue = $true },
    @{ Name = 'unsupported-producer'; Values = @{ ControllerPrecursor = 'not-a-producer'; ControllerPrecursorArtifactPath = 'inert.json' }; Exit = 1; ClosedValue = $true }
  )
  foreach ($runnerName in $runners.Keys) {
    $runner = Join-Path $root "$runnerName-runner.ps1"
    [IO.File]::WriteAllText($runner, $runners[$runnerName])
    foreach ($case in $cases) {
      if (Test-Path -LiteralPath $body) { Remove-Item -LiteralPath $body -Force }
      $parameters = @{ Worktree = $root; Lane = 'inert' } + $case.Values
      [IO.File]::WriteAllText($inputPath, ($parameters | ConvertTo-Json -Compress))
      $output = (& pwsh -NoProfile -NonInteractive -File $runner $guard $inputPath 2>&1 | Out-String).Trim()
      $code = $LASTEXITCODE
      if ($code -ne $case.Exit -or (Test-Path -LiteralPath $body) -ne [bool]$case.Body -or
          ($output -match 'parameter set refusal:') -ne [bool]$case.Binding -or
          ([bool]$case.Binding -and $output -notmatch 'MissingMandatoryParameter') -or
          ([bool]$case.ClosedValue -and $output -cne 'heavy-verifier: invalid closed route value')) {
        throw "actual $runnerName runner $($case.Name): expected=$($case.Exit) actual=$code output=$output"
      }
    }
  }
  $precursorWrites = @($test.FindAll({ param($node)
    $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ceq 'Set-Content' -and
      $node.CommandElements.Count -eq 5 -and $node.CommandElements[2].Extent.Text -ceq '$precursorRunner'
  }, $true))
  if ($precursorWrites.Count -ne 1) { throw 'expected one actual precursor runner definition' }
  $precursorRunner = Join-Path $root 'precursor-runner.ps1'
  [IO.File]::WriteAllText($precursorRunner, $precursorWrites[0].CommandElements[4].SafeGetValue())
  $start = [Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'pwsh.exe'))
  $start.UseShellExecute = $false; $start.CreateNoWindow = $true
  $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
  foreach ($argument in @('-NoProfile','-NonInteractive','-File',$precursorRunner)) { [void]$start.ArgumentList.Add($argument) }
  $environment = @{ HV_GUARD = $guard; HV_WORKTREE = $root; HV_CONTAINER = $root; HV_LANE = 'inert'; HV_PRECURSOR = 'not-a-producer'; HV_PRECURSOR_OUTPUT = 'unknown.json'; HV_PRECURSOR_SCENARIO = ''; HV_BRANCH = 'inert'; HV_CLAIMED_HEAD = 'inert'; HV_IMMUTABLE_HEAD = ''; HV_IDENTITY_DELAY = '0'; HV_CANCEL = '0'; HV_INJECT_COMMAND = '0'; HV_INJECT_SCRIPT = '0' }
  foreach ($entry in $environment.GetEnumerator()) { $start.Environment[$entry.Key] = $entry.Value }
  $child = [Diagnostics.Process]::Start($start)
  try {
    $out = $child.StandardOutput.ReadToEndAsync(); $err = $child.StandardError.ReadToEndAsync()
    $child.WaitForExit()
    $unknownProducer = @{ exitCode = $child.ExitCode; output = $out.GetAwaiter().GetResult() + $err.GetAwaiter().GetResult() }
  } finally { $child.Dispose() }
  $unknownOut = 'unknown.json'; $worktree = $root
  $unknown = @($test.FindAll({ param($node)
    $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ceq 'Assert-True' -and
      $node.Extent.Text.EndsWith('"unknown precursor producer is rejected by the closed allowlist"', [StringComparison]::Ordinal)
  }, $true))
  if ($unknown.Count -ne 1) { throw 'expected one ordinary unknown-producer assertion' }
  . ([scriptblock]::Create($unknown[0].Extent.Text))
  . ([scriptblock]::Create((Find-Definition $test 'Invoke-Precursor').Extent.Text))
  function Invoke-FixtureGit([string[]]$Arguments) { 'inert' }
  function Get-DefaultPrecursorScenario([string]$Producer) { 'ReceiptClaims' }
  $container = $root; $commandOut = 'command-injection.json'
  $commandInjection = Invoke-Precursor 'fail-closed-guard-evidence' $commandOut @{ InjectCommand = $true }
  $commandAssertion = @($test.FindAll({ param($node)
    $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ceq 'Assert-True' -and
      $node.Extent.Text.EndsWith('"CommandPath and arbitrary argument list are unavailable to ControllerPrecursor"', [StringComparison]::Ordinal)
  }, $true))
  if ($commandAssertion.Count -ne 1) { throw 'expected one ordinary precursor command-injection assertion' }
  . ([scriptblock]::Create($commandAssertion[0].Extent.Text))
  # Reuse the ordinary legacy negative assertion with the actual early validator.
  $worktree = $root; $container = $root; $currentFixtureHead = 'inert'
  $bypass = @($test.FindAll({ param($node)
    $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ceq 'Assert-True' -and
      $node.Extent.Text.EndsWith('"unsupported gate bypass is refused"', [StringComparison]::Ordinal)
  }, $true))
  if ($bypass.Count -ne 1) { throw 'expected one ordinary unsupported-gate assertion' }
  $bypassFailed = $false; $bypassOutput = $null
  try { & $guard -Gate 'not-a-heavy-gate' -Worktree $worktree -Lane 'inert' } catch { $bypassFailed = $true; $bypassOutput = $_.Exception.Message }
  . ([scriptblock]::Create($bypass[0].Extent.Text))
  if (Test-Path -LiteralPath $body) { throw 'closed-value refusal must not reach the inert body' }
  Write-Output 'PASS actual closed-route fixture runners: valid routes reach inert body; crossed selectors/commands refuse with typed binding diagnostics and exit 1; scalar refusals stay distinct; command-metadata mutants refuse; no admission, native helper, Job or signal'
} finally {
  $full = [IO.Path]::GetFullPath($root)
  if ([IO.Path]::GetDirectoryName($full) -ine $temp -or [IO.Path]::GetFileName($full) -cnotmatch '^closed-route-binding-[0-9a-f]{32}$') { throw 'refusing cleanup outside private binding fixture' }
  if (Test-Path -LiteralPath $full) { Remove-Item -LiteralPath $full -Recurse -Force }
}
