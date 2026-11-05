$ErrorActionPreference='Stop'
$script:checks=0
function Check([bool]$Condition,[string]$Message) {
  $script:checks++
  if(-not $Condition){throw "ASSERTION FAILED: $Message"}
}
$root=Join-Path ([IO.Path]::GetTempPath()) ('ledger-integration-contract-paths-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
$module=$null
try {
  $entry=Join-Path $PSScriptRoot 'integration-dispatch-contract.ps1'
  $tokens=$null;$errors=$null
  $ast=[Management.Automation.Language.Parser]::ParseFile($entry,[ref]$tokens,[ref]$errors)
  Check ($errors.Count -eq 0) 'integration contract parses'
  $import="Import-Module (Join-Path `$PSScriptRoot 'dispatch-ledger-reader.psm1') -DisableNameChecking"
  $imports=@($ast.EndBlock.Statements|Where-Object {$_.Extent.Text -ceq $import})
  Check ($imports.Count -eq 1) 'literal unconditional sole-owner import'
  $reads=@($ast.FindAll({param($node)
    ($node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ceq 'Get-Content') -or
    ($node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and
      $node.Expression.Extent.Text -ceq '[IO.File]' -and $node.Member.Value -cin @('Open','ReadAllText','ReadAllBytes'))
  },$true))
  $paths=@('$PoolStatusFixturePath','$AckPath','$specPath','$path','$spec.originalPromptPath',
    '$requestPath','$spec.partialReportPath','$AckPath','$specPath','$spec.partialReportPath','$spec.originalPromptPath')
  Check ($reads.Count -eq 11 -and $reads.Count -eq $paths.Count) 'eleven native non-dispatch paths'
  Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'dispatch-ledger-reader.psm1') -Destination $root
  $payload='{"accounts":[{"provider":"codex","disabled":false}]}'
  $positive=Join-Path $root 'pool-status.json'
  [IO.File]::WriteAllText($positive,$payload,[Text.UTF8Encoding]::new($false))
  $bytes=[IO.File]::ReadAllBytes($positive)
  $aliases=@('dispatch-log.jsonl','DISPATCH-LOG.JSONL','./dispatch-log.jsonl',
    'dispatch-log.jsonl.','dispatch-log.jsonl ','dispatch-log.jsonl:integration','dispatch-log.jsonl.:integration')
  $bindings=@'
$PoolStatusFixturePath=$AckPath=$specPath=$path=$requestPath=$ProbePath
$spec=[pscustomobject]@{originalPromptPath=$ProbePath;partialReportPath=$ProbePath}
'@
  $probe=Join-Path $root 'probe.ps1'
  for($index=0;$index -lt $reads.Count;$index++) {
    $read=$reads[$index]
    $guard="(dispatch-ledger-reader\Get-NonDispatchLedgerPath -Path $($paths[$index]))"
    Check ($read.Extent.Text.Contains($guard,[StringComparison]::Ordinal)) "original path guarded index=$index"
    Check ($imports[0].Extent.EndOffset -lt $read.Extent.StartOffset) "import precedes read index=$index"
    if($read -is [Management.Automation.Language.CommandAst]) {
      Check ($read.Extent.Text -ceq "Get-Content -LiteralPath $guard -Raw") 'fixture retains literal/raw semantics'
    } else {
      $expected=if($read.Member.Value -ceq 'Open') {
        "[IO.File]::Open($guard,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)"
      } else {"[IO.File]::$($read.Member.Value)($guard)"}
      Check ($read.Extent.Text -ceq $expected) "native overload unchanged index=$index"
    }
    # Execute production AST text, not a substitute reader or a copied guard.
    [IO.File]::WriteAllText($probe,('param([string]$ProbePath)'+"`n"+$import+"`n"+$bindings+"`n"+$read.Extent.Text))
    $result=& $probe $positive
    if($read -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $read.Member.Value -ceq 'Open') {
      try {
        Check ($result.CanRead -and -not $result.CanWrite) 'retained lock remains read-only'
        $buffer=[IO.MemoryStream]::new()
        try {$result.CopyTo($buffer);$actual=$buffer.ToArray()}finally{$buffer.Dispose()}
        Check ([Linq.Enumerable]::SequenceEqual([byte[]]$actual,$bytes)) 'retained lock exact bytes'
        $blocked=$false
        try {$writer=[IO.File]::Open($positive,'Open','Write','ReadWrite');$writer.Dispose()}catch{$blocked=$true}
        Check $blocked 'retained lock still denies writes'
      } finally {$result.Dispose()}
    } elseif($read -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $read.Member.Value -ceq 'ReadAllBytes') {
      Check ([Linq.Enumerable]::SequenceEqual([byte[]]$result,$bytes)) "exact native bytes index=$index"
    } else {Check ($result -ceq $payload) "exact native text index=$index"}
    foreach($alias in $aliases) {
      $target=Join-Path $root $alias
      [IO.File]::WriteAllText($target,$payload)
      $held=[IO.File]::Open($target,'Open','ReadWrite','None')
      try {
        $failure=''
        try {& $probe $target|Out-Null}catch{$failure=$_.Exception.Message}
        Check ($failure -like '*DISPATCH_LEDGER_OWNER_REQUIRED*') "pre-I/O owner refusal index=$index alias=$alias failure=$failure"
      } finally {$held.Dispose()}
      Check ([IO.File]::ReadAllText($target) -ceq $payload) 'valid alias bytes untouched'
    }
  }
  $history=@($ast.FindAll({param($node)
    $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ceq 'Read-ExactHeadReviewHistory'
  },$true))
  Check ($history.Count -eq 2) 'both real dispatch-history owner APIs retained'
  foreach($call in $history) {Check ($call.Extent.Text -ceq 'Read-ExactHeadReviewHistory -Path $HistoryPath') 'history path not relabeled as non-dispatch'}

  # Load complete production bodies without routing-data top-level initialization.
  $definitions=[Collections.Generic.List[string]]::new()
  foreach($name in @('Read-PoolStatus','Get-RetainedIntegrationStart')) {
    $definition=$ast.Find({param($node)
      $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name
    },$true)
    Check ($null -ne $definition) "complete production function: $name"
    $definitions.Add($definition.Extent.Text)
  }
  $functions=Join-Path $root 'functions.ps1'
  [IO.File]::WriteAllText($functions,($import+"`n"+($definitions -join "`n")))
  . $functions
  $module=Import-Module (Join-Path $PSScriptRoot 'landed-integration-evidence.psm1') -Force -DisableNameChecking -PassThru
  Check ((Read-PoolStatus $positive).accounts[0].provider -ceq 'codex') 'full pool-status body parses native payload'
  $ackPath=Join-Path $root 'ack.json'
  [IO.File]::WriteAllText($ackPath,'{}')
  $pr=[pscustomobject]@{number=1;headRefOid=('a'*40)}
  $result=Get-RetainedIntegrationStart $ackPath ('b'*64) $pr $root $root (Join-Path $root 'dispatch-log.jsonl')
  Check ($result.reason -ceq 'ack identity' -and $result.action -ceq 'RETAINED_START_PENDING') 'full retained body reads real JSON and preserves malformed-ack refusal'
  $exclusive=[IO.File]::Open($ackPath,'Open','ReadWrite','None');$exclusive.Dispose()
  Check $true 'full retained body releases acquired lock on validation failure'
  foreach($alias in $aliases) {
    $target=Join-Path $root $alias
    [IO.File]::WriteAllText($target,$payload)
    $held=[IO.File]::Open($target,'Open','ReadWrite','None')
    try {
      Check ($null -eq (Read-PoolStatus $target)) 'full pool-status body preserves unknown fallback on owner refusal'
      $result=Get-RetainedIntegrationStart $target ('b'*64) $pr $root $root $target
      Check ($result.reason -like '*DISPATCH_LEDGER_OWNER_REQUIRED*' -and $result.action -ceq 'RETAINED_START_PENDING') 'full retained body reports owner refusal before native open'
    } finally {$held.Dispose()}
  }
  # Resume reducers dot-source the complete contract inside the evidence module.
  # A forced owner reload here invalidates its module-qualified self-call.
  # Use a fresh native process: earlier extracted reads can prime command caches.
  $nestedProbe=Join-Path $root 'nested-owner.ps1'
  [IO.File]::WriteAllText($nestedProbe,@'
param([string]$OwnerRoot,[string]$FixtureRoot)
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $OwnerRoot 'landed-integration-evidence.psm1') -Force -DisableNameChecking -PassThru
$entry=Join-Path $OwnerRoot 'integration-dispatch-contract.ps1'
$positive=Join-Path $FixtureRoot 'pool-status.json'
$aliases=@('dispatch-log.jsonl','DISPATCH-LOG.JSONL','./dispatch-log.jsonl',
  'dispatch-log.jsonl.','dispatch-log.jsonl ','dispatch-log.jsonl:integration','dispatch-log.jsonl.:integration')
foreach($iteration in 1..2) {
  $nested=& $module {param($Entry,$Path) . $Entry; Read-RebaseJson $Path} $entry $positive
  if($nested.accounts[0].provider -cne 'codex'){throw 'nested native payload changed'}
  foreach($alias in $aliases) {
    $target=Join-Path $FixtureRoot $alias
    $held=[IO.File]::Open($target,'Open','ReadWrite','None')
    try {
      $failure=''
      try {& $module {param($Entry,$Path) . $Entry; Read-RebaseJson $Path} $entry $target|Out-Null}catch{$failure=$_.Exception.Message}
      if($failure -notlike '*DISPATCH_LEDGER_OWNER_REQUIRED*'){throw "nested owner refusal absent: $failure"}
    } finally {$held.Dispose()}
  }
}
'PASS native nested owner imports=16 aliases=7'
'@)
  $nestedOutput=@(& (Join-Path $PSHOME 'pwsh.exe') -NoProfile -NonInteractive -File $nestedProbe $PSScriptRoot $root 2>&1)
  Check ($LASTEXITCODE -eq 0 -and 'PASS native nested owner imports=16 aliases=7' -cin $nestedOutput) "fresh native nested imports: $($nestedOutput -join ' ')"
  Write-Output "PASS ledger-reader-integration-contract-paths checks=$script:checks native=11 unguarded=0 nestedImports=16"
} finally {
  if($module){Remove-Module $module -Force}
  $full=[IO.Path]::GetFullPath($root)
  if((Split-Path -Parent $full).TrimEnd('\','/') -cne ([IO.Path]::GetFullPath([IO.Path]::GetTempPath())).TrimEnd('\','/') -or
    (Split-Path -Leaf $full) -cnotlike 'ledger-integration-contract-paths-*'){throw 'unsafe integration contract fixture cleanup'}
  Remove-Item -LiteralPath $full -Recurse -Force
}
