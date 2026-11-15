$ErrorActionPreference = 'Stop'
function Assert-True($Condition, [string]$Message) { if (-not $Condition) { throw "ASSERTION FAILED: $Message" } }
$source = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'admission-temp-cleanup.test.ps1'))
$ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$null, [ref]$null)
$reads = @($ast.FindAll({param($node)
  $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -ceq '$beforeSource'
}, $true))
Assert-True ($reads.Count -eq 1) 'one actual immutable cleanup input read'
$read = $reads[0]
$statements = @($read.Parent.Statements)
$index = 0
while ($statements[$index].Extent.StartOffset -ne $read.Extent.StartOffset) { $index++ }
$assertion = $statements[$index + 1].Extent.Text
Assert-True ($assertion -ceq "Assert-True(`$LASTEXITCODE-eq0)'immutable cleanup carrier unavailable'") 'original readability assertion is unchanged and immediately follows the read'
$pin = '611c05666a74e39444cbf84e3e0ff2369d94a27b'
function Read-ActualCleanupInput([switch]$Missing) {
  $code = $read.Extent.Text
  if ($Missing) { $code = $code.Replace($pin, ('f' * 40)) }
  return & ([scriptblock]::Create($code + "`n" + $assertion + "`n" + '$beforeSource'))
}
$actual = Read-ActualCleanupInput
$path = Join-Path $PSScriptRoot 'fixtures/historical-cleanup-carrier/.orchestrator/admission-temp-cleanup-before.ps1'
$hash = & git.exe hash-object --no-filters -- $path
Assert-True ($LASTEXITCODE -eq 0 -and $hash -ceq $pin) 'archived cleanup carrier retains the original raw Git blob'
$expected = [IO.File]::ReadAllText($path).Replace("`r`n", "`n").TrimEnd([char[]]"`n")
Assert-True ($actual.TrimEnd([char[]]"`n") -ceq $expected) 'ordinary cleanup read returns exactly the original public source'
$missing = $false
try { Read-ActualCleanupInput -Missing | Out-Null } catch { $missing = $_.Exception.Message -ceq 'ASSERTION FAILED: immutable cleanup carrier unavailable' }
Assert-True $missing 'missing object still refuses at the ordinary readability assertion'
$beforeLines = @($actual -split "`n" | Where-Object { $_ -like 'function Stop-Exact*' })
Assert-True ($beforeLines.Count -eq 1) 'original Stop-Exact source is unambiguous'
$converted = $beforeLines[0].Replace('Stop-Exact($Value)', 'Stop-Before($Value,[scriptblock]$BetweenObservations)').Replace(';Assert-True', ';& $BetweenObservations;Assert-True')
$parsed = [Management.Automation.Language.Parser]::ParseInput($converted, [ref]$null, [ref]$null)
$definitions = @($parsed.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst]}, $false))
Assert-True ($definitions.Count -eq 1 -and $definitions[0].Name -ceq 'Stop-Before' -and $converted.Contains(';& $BetweenObservations;Assert-True')) 'unchanged ordinary transformation retains its historical control and barrier'
Write-Output 'PASS actual immutable cleanup read: original public raw blob, exact source, missing-object refusal and inert historical transformation; no cleanup/process/signal execution'
