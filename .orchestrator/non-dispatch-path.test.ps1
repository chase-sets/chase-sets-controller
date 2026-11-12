[CmdletBinding()]param()
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'dispatch-ledger-reader.psm1') -Force -DisableNameChecking
function Assert-PathTest([bool]$Condition,[string]$Message) {
  if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}
function Get-TestFunction([string]$File,[string]$Name) {
  $tokens=$null;$errors=$null
  $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $File),[ref]$tokens,[ref]$errors)
  Assert-PathTest ($errors.Count -eq 0) "$File parses"
  $functions=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $Name},$true))
  Assert-PathTest ($functions.Count -eq 1) "$File has exactly one $Name"
  return $functions[0]
}
$helpers=@(
  @{file='digest-publish.ps1';name='Read-DigestRows';extra=@{Tail=20}},
  @{file='matrix-refresh.ps1';name='Read-Jsonl';extra=@{}},
  @{file='landed-integration-evidence.psm1';name='Read-RebaseJsonLines';extra=@{}}
)
# Load only the real function definitions, never either script's workflow.
foreach ($helper in $helpers) {
  $helper.ast=Get-TestFunction $helper.file $helper.name
  . ([scriptblock]::Create($helper.ast.Extent.Text))
}
$converter=Get-TestFunction 'landed-integration-evidence.psm1' 'ConvertFrom-RebaseJson'
. ([scriptblock]::Create($converter.Extent.Text))
$root=Join-Path ([IO.Path]::GetTempPath()) ('non-dispatch-path-'+[guid]::NewGuid().ToString('N'))
try {
  [void](New-Item -ItemType Directory -Path $root)
  $dispatch=Join-Path $root 'dispatch-log.jsonl'
  [IO.File]::WriteAllText($dispatch,"{`"kind`":`"dispatch`"}`n",[Text.UTF8Encoding]::new($false))
  if ($IsWindows) {
    foreach ($alias in @(($dispatch+' '),($dispatch+'.'),($dispatch+'::$DATA'))) {
      Assert-PathTest ([IO.File]::ReadAllText($alias) -ceq [IO.File]::ReadAllText($dispatch)) 'Windows native spelling reaches the canonical file'
    }
    Write-Output 'PASS Windows trailing-space, trailing-dot and default-stream aliases reach the same synthetic dispatch file'
  }
  $readFailures=@{}
  foreach ($helper in $helpers) {
    $extra=$helper.extra
    $failure=$null
    try { & $helper.name -Path $dispatch @extra | Out-Null } catch { $failure=$_.Exception.Message }
    Assert-PathTest ($failure -ceq 'DISPATCH_LEDGER_OWNER_REQUIRED') "$($helper.name) must refuse a dispatch path without DispatchHistory (got '$failure')"
  }

  $blocked=@('dispatch-log.jsonl','DISPATCH-LOG.JSONL','./dispatch-log.jsonl',
    '.\Dispatch-Log.Jsonl','nested/dispatch-log.jsonl','nested\dispatch-log.jsonl',
    $dispatch,($dispatch -replace '\\','/'),'dispatch-log.jsonl ',
    'dispatch-log.jsonl.','dispatch-log.jsonl::$DATA','dispatch-log.jsonl:stream')
  $allowed=@('cost-ledger.jsonl','receipts.jsonl','./cost-ledger.jsonl',
    '.\receipts.jsonl',(Join-Path $root 'cost-ledger.jsonl'),
    (Join-Path $root 'receipts.jsonl'),'dispatch-log.jsonl.receipt')
  foreach ($path in $blocked) {
    $failure=$null
    try { dispatch-ledger-reader\Assert-NonDispatchLedgerPath -Path $path } catch { $failure=$_.Exception.Message }
    Assert-PathTest ($failure -ceq 'DISPATCH_LEDGER_OWNER_REQUIRED') "assertion refuses $path"
  }
  foreach ($path in $allowed) {
    $output=@(dispatch-ledger-reader\Assert-NonDispatchLedgerPath -Path $path)
    Assert-PathTest ($output.Count -eq 0) "assertion emits nothing for $path"
  }

  foreach ($helper in $helpers) {
    # Require a real conditional's ELSE block to start with the qualified guard,
    # followed immediately by the native read, rather than trusting flag mentions.
    $branches=@($helper.ast.FindAll({param($node) $node -is [Management.Automation.Language.IfStatementAst] -and
      $node.Clauses[0].Item1.Extent.Text -ceq '$DispatchHistory'},$true))
    Assert-PathTest ($branches.Count -eq 1) "$($helper.name) has one dispatch conditional"
    $statements=@($branches[0].ElseClause.Statements)
    Assert-PathTest ($statements.Count -eq 2) "$($helper.name) ELSE contains only guard then native read"
    $commands=@($statements[0].FindAll({param($node) $node -is [Management.Automation.Language.CommandAst]},$true))
    Assert-PathTest ($commands.Count -eq 1 -and $commands[0].GetCommandName() -ceq 'dispatch-ledger-reader\Assert-NonDispatchLedgerPath' -and
      $commands[0].Extent.Text -ceq 'dispatch-ledger-reader\Assert-NonDispatchLedgerPath -Path $Path') "$($helper.name) guard is qualified and receives Path"
    Assert-PathTest ($statements[1].Extent.Text -match '^(Get-Content -LiteralPath \$Path|\[IO.File\]::ReadAllLines\(\$Path,)') "$($helper.name) native read immediately follows guard"
    $extra=$helper.extra
    # An exclusive handle makes any attempted native read fail differently.
    $lock=[IO.File]::Open($dispatch,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try {
      $failure=$null
      try { & $helper.name -Path $dispatch @extra | Out-Null } catch { $failure=$_.Exception.Message }
      Assert-PathTest ($failure -ceq 'DISPATCH_LEDGER_OWNER_REQUIRED') "$($helper.name) throws before native read of locked dispatch file"
    } finally { $lock.Dispose() }
    $rows=@(& $helper.name -Path $dispatch -DispatchHistory @extra)
    Assert-PathTest ($rows.Count -eq 1 -and $rows[0].kind -ceq 'dispatch') "$($helper.name) dispatch branch retains shared owner behavior"
    foreach ($leaf in @('cost-ledger.jsonl','receipts.jsonl')) {
      $path=Join-Path $root $leaf
      [IO.File]::WriteAllText($path,"{`"usd`":1}`n`n{`"usd`":2}`n",[Text.UTF8Encoding]::new($false))
      $rows=@(& $helper.name -Path $path @extra)
      Assert-PathTest ($rows.Count -eq 2 -and $rows[0].usd -eq 1 -and $rows[1].usd -eq 2) "$($helper.name) preserves native $leaf rows"
    }
  }
  # Existing malformed and missing non-dispatch behavior remains helper-specific.
  $bad=Join-Path $root 'bad-receipts.jsonl'
  [IO.File]::WriteAllText($bad,"{bad`n",[Text.UTF8Encoding]::new($false))
  foreach ($name in @('Read-DigestRows','Read-RebaseJsonLines')) {
    $extra=if ($name -ceq 'Read-DigestRows') { @{Tail=20} } else { @{} }
    $failure=$null
    try { & $name -Path $bad @extra | Out-Null } catch { $failure=$_.Exception.Message }
    Assert-PathTest ($null -ne $failure -and $failure -cne 'DISPATCH_LEDGER_OWNER_REQUIRED') "$name retains malformed receipt failure"
  }
  $rows=@(Read-Jsonl -Path $bad)
  Assert-PathTest ($rows.Count -eq 0 -and $readFailures[$bad]) 'matrix retains malformed receipt readFailures behavior'
  $missing=Join-Path $root 'missing-receipts.jsonl'
  Assert-PathTest (@(Read-DigestRows -Path $missing -Tail 20).Count -eq 0) 'digest retains missing cost behavior'
  Assert-PathTest (@(Read-Jsonl -Path $missing).Count -eq 0) 'matrix retains missing receipt behavior'
  $failure=$null
  try { Read-RebaseJsonLines -Path $missing | Out-Null } catch { $failure=$_.Exception.Message }
  Assert-PathTest ($null -ne $failure -and $failure -cne 'DISPATCH_LEDGER_OWNER_REQUIRED') 'rebase retains native missing receipt failure'
  Write-Output 'PASS non-dispatch path assertion and three actual helper bodies: guard before native read, dispatch owner, cost/receipt behavior'
} finally {
  $resolved=[IO.Path]::GetFullPath($root)
  $temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
  if (-not $resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notlike 'non-dispatch-path-*') { throw 'unsafe test cleanup path' }
  if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
