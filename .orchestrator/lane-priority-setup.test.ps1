$ErrorActionPreference = 'Stop'
function Assert-Setup([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}
$source = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'lane-priority.test.ps1'))
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$null, [ref]$errors)
Assert-Setup (-not $errors) 'ordinary priority fixture parses'
$runner = @($ast.FindAll({ param($node)
  $node -is [Management.Automation.Language.CommandAst] -and
    $node.GetCommandName() -ceq 'Write-Text' -and
    $node.CommandElements.Count -eq 3 -and
    $node.CommandElements[1].Extent.Text -ceq '$runner'
}, $true))
Assert-Setup ($runner.Count -eq 1) 'one actual synthetic runner definition'
$body = $runner[0].CommandElements[2].Value
$boundary = '$global:priorityProbeRuntime=$Runtime'
Assert-Setup ($body.Split(@($boundary), [StringSplitOptions]::None).Count -eq 2) 'one runner setup boundary'
$prefix = $body.Substring(0, $body.IndexOf($boundary, [StringComparison]::Ordinal))
$hostPriority = [Diagnostics.Process]::GetCurrentProcess().PriorityClass
function Read-InertSetupPriority([string]$Setup) {
  # Only this short-lived child changes priority; no dispatcher or census runs.
  $command = '[Diagnostics.Process]::GetCurrentProcess().PriorityClass="BelowNormal";' +
    '& {' + $Setup + '};[Console]::Write([Diagnostics.Process]::GetCurrentProcess().PriorityClass)'
  $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
  $observed = & (Join-Path $PSHOME 'pwsh.exe') -NoProfile -NonInteractive -EncodedCommand $encoded
  Assert-Setup ($LASTEXITCODE -eq 0) 'isolated priority setup executes'
  return [string]$observed
}
Assert-Setup ((Read-InertSetupPriority $prefix) -ceq 'Normal') 'actual runner setup restores inherited BelowNormal before admission'
$setter = '[Diagnostics.Process]::GetCurrentProcess().PriorityClass = "Normal"'
Assert-Setup ($prefix.Split(@($setter), [StringSplitOptions]::None).Count -eq 2) 'one explicit synthetic runner priority prerequisite'
Assert-Setup ((Read-InertSetupPriority ($prefix.Replace($setter, '# omitted setup mutant'))) -ceq 'BelowNormal') 'omitted setup mutant retains inherited priority'
Assert-Setup ([Diagnostics.Process]::GetCurrentProcess().PriorityClass -eq $hostPriority) 'host priority unchanged'
Write-Output 'PASS actual synthetic runner priority setup from inherited BelowNormal; omitted setup mutant distinguished; host unchanged; no dispatcher executed'
