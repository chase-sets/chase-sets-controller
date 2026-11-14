$ErrorActionPreference = 'Stop'
$errors = $null
$verifier = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'invoke-heavy-verifier.ps1'), [ref]$null, [ref]$errors)
if ($errors.Count) { throw 'actual verifier must parse' }
$statements = @($verifier.EndBlock.Statements)
$completion = @($statements | Where-Object {
  $_ -is [Management.Automation.Language.IfStatementAst] -and
    $_.Clauses[0].Item1.Extent.Text -ceq '$script:heavyAdmissionQuitAfterQuarantine'
})
if ($completion.Count -ne 1) { throw 'expected one actual completed-quarantine exit boundary' }
$index = [array]::IndexOf($statements, $completion[0])
if ($index -lt 1 -or -not $statements[$index - 1].Extent.Text.StartsWith('Invoke-HeavyAdmissionCensus ', [StringComparison]::Ordinal)) {
  throw 'completion exit must remain after the actual admission census and its cleanup'
}
$fifo = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'invoke-heavy-verifier-fifo.test.ps1'), [ref]$null, [ref]$errors)
if ($errors.Count) { throw 'ordinary FIFO test must parse' }
$runnerWrite = @($fifo.FindAll({ param($node)
  $node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and
    $node.Expression.Extent.Text -ceq '[IO.File]' -and $node.Member.Value -ceq 'WriteAllText' -and
    $node.Arguments.Count -eq 2 -and $node.Arguments[0].Extent.Text -ceq '$runner'
}, $true))
if ($runnerWrite.Count -ne 1) { throw 'expected one actual FIFO runner definition' }
$runnerSource = $runnerWrite[0].Arguments[1].SafeGetValue()
$temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/')
$root = Join-Path $temp ('queue-recovery-exit-' + [guid]::NewGuid().ToString('N'))
try {
  [void][IO.Directory]::CreateDirectory($root)
  $runner = Join-Path $root 'runner.ps1'
  $guard = Join-Path $root 'guard.ps1'
  $inputPath = Join-Path $root 'input.json'
  [IO.File]::WriteAllText($runner, $runnerSource)
  [IO.File]::WriteAllText($guard, @'
param([bool]$Completed, [int]$PriorExit, [bool]$Refused)
$global:LASTEXITCODE = $PriorExit
$script:heavyAdmissionQuitAfterQuarantine = $Completed
if ($Refused) { exit 73 }
'@ + "`n" + $completion[0].Extent.Text + "`n[Console]::WriteLine('inert fallthrough'); exit 91")
  $cases = @(
    @{ Name = 'completed-stale-128'; Completed = $true; PriorExit = 128; Expected = 0 },
    @{ Name = 'completed-stale-73'; Completed = $true; PriorExit = 73; Expected = 0 },
    @{ Name = 'completed-zero'; Completed = $true; PriorExit = 0; Expected = 0 },
    @{ Name = 'not-completed'; PriorExit = 128; Expected = 91; Fallthrough = $true },
    @{ Name = 'refused'; PriorExit = 128; Refused = $true; Expected = 73 },
    @{ Name = 'refusal-before-completion'; Completed = $true; PriorExit = 128; Refused = $true; Expected = 73 }
  )
  foreach ($case in $cases) {
    $parameters = @{ Completed = [bool]$case.Completed; PriorExit = $case.PriorExit; Refused = [bool]$case.Refused }
    [IO.File]::WriteAllText($inputPath, ($parameters | ConvertTo-Json -Compress))
    $output = & pwsh -NoProfile -NonInteractive -File $runner $guard $inputPath 2>&1 | Out-String
    $code = $LASTEXITCODE
    if ($code -ne $case.Expected -or $output.Contains('inert fallthrough') -ne [bool]$case.Fallthrough) {
      throw "actual completed-quarantine boundary $($case.Name): expected=$($case.Expected) actual=$code output=$output"
    }
  }
  Write-Output 'PASS actual quarantine completion exits zero through the actual FIFO runner despite stale native exits; noncompletion and prior refusal stay nonzero; no admission or native probe'
} finally {
  $full = [IO.Path]::GetFullPath($root)
  if ([IO.Path]::GetDirectoryName($full) -ine $temp -or [IO.Path]::GetFileName($full) -cnotmatch '^queue-recovery-exit-[0-9a-f]{32}$') {
    throw 'refusing cleanup outside the private recovery-exit fixture'
  }
  if (Test-Path -LiteralPath $full) { Remove-Item -LiteralPath $full -Recurse -Force }
}
