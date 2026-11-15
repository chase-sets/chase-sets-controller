$ErrorActionPreference = 'Stop'
function Assert-True($Condition, [string]$Message) { if (-not $Condition) { throw "ASSERTION FAILED: $Message" } }
$source = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'review-head-reducer.test.ps1'))
$ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$null, [ref]$null)
function Get-Assignment([string]$Name) {
  $nodes = @($ast.FindAll({param($node)
    $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -ceq $Name
  }, $true))
  Assert-True ($nodes.Count -eq 1) "one actual assignment: $Name"
  return $nodes[0]
}
$map = (Get-Assignment '$ordinaryBaselineBlobs').Right.Expression.SafeGetValue()
Assert-True ($map.Count -eq 2 -and
  $map['.orchestrator/review-head-contract.psm1'] -ceq '4139444d8af64a8f0dadee2bf4b095dcde87a2d0' -and
  $map['.orchestrator/review-head-reducer.ps1'] -ceq '0d15b88f300fb1cfcbc99974ab44a0e340ea3ea9') 'ordinary baseline map retains exactly the original two blobs'
$cases = @(
  @{ name='$baselineSource'; pin='d02e647f06e87ffbec69f4f6828f0d9f22ffbecb'; file='.orchestrator/equivalence-review-head-contract.psm1'; guard="if(`$LASTEXITCODE-ne0){throw 'cannot extract reducer equivalence baseline'}"; refusal='cannot extract reducer equivalence baseline' },
  @{ name='$sourceLines'; relative='.orchestrator/review-head-contract.psm1'; pin='4139444d8af64a8f0dadee2bf4b095dcde87a2d0'; file='.orchestrator/ordinary/review-head-contract.psm1'; guard='Assert-True ($LASTEXITCODE-eq0-and$sourceLines.Count-gt0) "ordinary reducer baseline source must be readable at $ordinaryBaseline"'; refusal='ASSERTION FAILED: ordinary reducer baseline source must be readable at 8d1affe3d308443155eb3d81eaa619c345e1124e' },
  @{ name='$sourceLines'; relative='.orchestrator/review-head-reducer.ps1'; pin='0d15b88f300fb1cfcbc99974ab44a0e340ea3ea9'; file='.orchestrator/ordinary/review-head-reducer.ps1'; guard='Assert-True ($LASTEXITCODE-eq0-and$sourceLines.Count-gt0) "ordinary reducer baseline source must be readable at $ordinaryBaseline"'; refusal='ASSERTION FAILED: ordinary reducer baseline source must be readable at 8d1affe3d308443155eb3d81eaa619c345e1124e' },
  @{ name='$baseline9382Source'; pin='4a54ac04fd0c800c7b3d54e7424f2994c0dfc1b8'; file='.orchestrator/installed-review-head-contract.psm1'; guard="Assert-True (`$LASTEXITCODE -eq 0) '9382 extract exact installed reducer baseline'"; refusal='ASSERTION FAILED: 9382 extract exact installed reducer baseline' }
)
function Read-ActualInput($Case, [switch]$Missing) {
  $read = Get-Assignment $Case.name
  $statements = @($read.Parent.Statements)
  $index = 0
  while ($statements[$index].Extent.StartOffset -ne $read.Extent.StartOffset) { $index++ }
  $guard = $statements[$index + 1].Extent.Text
  Assert-True ($guard -ceq $Case.guard) "unchanged immediate ordinary readability guard: $($Case.name)"
  $code = $read.Extent.Text
  $controllerRoot = Split-Path -Parent $PSScriptRoot
  $ordinaryBaseline = '8d1affe3d308443155eb3d81eaa619c345e1124e'
  $relative = $Case.relative
  $ordinaryBaselineBlobs = $map.Clone()
  if ($Missing) {
    $code = $code.Replace($Case.pin, ('f' * 40))
    if ($relative) { $ordinaryBaselineBlobs[$relative] = 'f' * 40 }
  }
  # Preserve the ordinary read's script root even when this inert block is
  # invoked outside a Git checkout. No module or reducer code is executed.
  $prefix = '$PSScriptRoot=$args[0]' + "`n"
  return & ([scriptblock]::Create($prefix + $code + "`n" + $guard + "`n" + $Case.name)) $PSScriptRoot
}
foreach ($case in $cases) {
  $actual = @(Read-ActualInput $case)
  $path = Join-Path $PSScriptRoot ('fixtures/historical-review-baselines/' + $case.file)
  $hash = & git.exe hash-object --no-filters -- $path
  Assert-True ($LASTEXITCODE -eq 0 -and $hash -ceq $case.pin) "original raw source blob: $($case.file)"
  $expected = [IO.File]::ReadAllText($path).Replace("`r`n", "`n").TrimEnd([char[]]"`n")
  Assert-True (($actual -join "`n").TrimEnd([char[]]"`n") -ceq $expected) "actual ordinary read returns the original source: $($case.file)"
  $refused = $false
  try { Read-ActualInput $case -Missing | Out-Null } catch { $refused = $_.Exception.Message -ceq $case.refusal }
  Assert-True $refused "missing blob refuses at its ordinary readability guard: $($case.file)"
}
Write-Output 'PASS four actual reducer baseline reads: original raw blobs, exact source and unchanged missing-object guards; no module import or reducer execution'
