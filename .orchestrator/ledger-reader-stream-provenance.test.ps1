$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ledger-reader-census.psm1') -Force
$checks = 0
function Check([bool]$Condition,[string]$Message) {
  $script:checks++
  if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}
$root = Join-Path ([IO.Path]::GetTempPath()) ('ledger-stream-provenance-'+[guid]::NewGuid().ToString('N'))
try {
  [void][IO.Directory]::CreateDirectory((Join-Path $root '.orchestrator'))
  Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'dispatch-ledger-reader.psm1') -Destination (Join-Path $root '.orchestrator')
  $sourcePath = Join-Path $root 'reader.ps1'
  [IO.File]::WriteAllText($sourcePath,'# tracked synthetic stream proof')
  & git -C $root init -q
  Check ($LASTEXITCODE -eq 0) 'fixture init'
  & git -C $root add reader.ps1 .orchestrator/dispatch-ledger-reader.psm1
  Check ($LASTEXITCODE -eq 0) 'fixture track'
  & git -C $root -c user.name=Synthetic -c user.email=synthetic@example.invalid commit -qm streams
  Check ($LASTEXITCODE -eq 0) 'fixture commit'
  $import = 'Import-Module (Join-Path $PSScriptRoot ''.orchestrator/dispatch-ledger-reader.psm1'') -Global -DisableNameChecking'
  $guard = '(dispatch-ledger-reader\Get-NonDispatchLedgerPath -Path $Path)'
  $open = '[IO.File]::Open('+$guard+',[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)'
  $construct = '[System.IO.FileStream]::new('+$guard+',[System.IO.FileMode]::Open,[System.IO.FileAccess]::Read,[System.IO.FileShare]::ReadWrite)'
  $read = '$reader=[IO.StreamReader]::new($stream)'
  $memory = '[IO.MemoryStream]::new($bytes,$false)'
  $memoryRead = '$reader=[IO.StreamReader]::new('+$memory+',[Text.Encoding]::UTF8,$true)'
  # An adjacent guarded open does not prove writable, untransformed storage or
  # successful assignment. Variable-fed constructors must remain unhandled.
  $cases = [ordered]@{
    inlineMemory = @($true,$memoryRead)
    inlineSystemMemory = @($true,$memoryRead.Replace('[IO.','[System.IO.').Replace('[Text.','[System.Text.'))
    inlineMemoryOtherBytes = @($true,$memoryRead.Replace('$bytes','$payload'))
    inlineMemoryDispatchBytes = @($false,('$bytes=[Text.Encoding]::UTF8.GetBytes(''dispatch-log.jsonl'');'+$memoryRead))
    inlineMemoryVariableStream = @($false,$memoryRead.Replace($memory,'$buffer'))
    inlineMemoryFactory = @($false,$memoryRead.Replace($memory,'(Get-Buffer $bytes)'))
    inlineMemoryOtherReceiver = @($false,$memoryRead.Replace('[IO.MemoryStream]','[Unknown.IO]'))
    inlineMemoryGeneric = @($false,$memoryRead.Replace('MemoryStream]::new(','MemoryStream]::new[int]('))
    inlineMemoryExtraArgument = @($false,$memoryRead.Replace('$bytes,$false','$bytes,$false,0'))
    inlineMemoryWritable = @($false,$memoryRead.Replace('$false','$true'))
    inlineMemoryVariableWritable = @($false,$memoryRead.Replace('$false','$writable'))
    inlineMemoryScopedBytes = @($false,$memoryRead.Replace('$bytes','$script:bytes'))
    inlineMemoryTransformedBytes = @($false,$memoryRead.Replace('$bytes','([byte[]]$bytes)'))
    inlineMemoryOpaqueBytes = @($false,$memoryRead.Replace('$bytes','(Get-Bytes)'))
    inlineMemoryVariableEncoding = @($false,$memoryRead.Replace('[Text.Encoding]::UTF8','$encoding'))
    inlineMemoryInvokedEncoding = @($false,$memoryRead.Replace('[Text.Encoding]::UTF8','[Text.Encoding]::UTF8()'))
    inlineMemoryOtherEncoding = @($false,$memoryRead.Replace('[Text.Encoding]','[Unknown.Encoding]'))
    inlineMemoryNoBomDetection = @($false,$memoryRead.Replace('$true)','$false)'))
    inlineMemoryVariableBomDetection = @($false,$memoryRead.Replace('$true)','$detectBom)'))
    inlineMemoryExtraDecoderArgument = @($false,$memoryRead.Replace('$true)','$true,4096)'))
    inlineGuardedFileStream = @($true,('$reader=[IO.StreamReader]::new('+$construct+')'))
    inlineUnguarded = @($false,('$reader=[IO.StreamReader]::new('+$construct.Replace($guard,'$Path')+')'))
    inlineOpaqueFactory = @($false,('$reader=[IO.StreamReader]::new((Get-Stream '+$guard+'))'))
    inlineOtherReceiver = @($false,('$reader=[IO.StreamReader]::new('+$construct.Replace('System.IO.FileStream','Unknown.IO')+')'))
    inlineVariableMode = @($false,('$reader=[IO.StreamReader]::new('+$construct.Replace('[System.IO.FileMode]::Open','$Mode')+')'))
    inlineVariableAccess = @($false,('$reader=[IO.StreamReader]::new('+$construct.Replace('[System.IO.FileAccess]::Read','$Access')+')'))
    inlineVariableShare = @($false,('$reader=[IO.StreamReader]::new('+$construct.Replace('[System.IO.FileShare]::ReadWrite','$Share')+')'))
    inlineInvokedAccess = @($false,('$reader=[IO.StreamReader]::new('+$construct.Replace('[System.IO.FileAccess]::Read','[System.IO.FileAccess]::Read()')+')'))
    inlineGenericConstructor = @($false,('$reader=[IO.StreamReader]::new('+$construct.Replace('::new(','::new[int](')+')'))
    inlineExtraDecoderArgument = @($false,('$reader=[IO.StreamReader]::new('+$construct+',$Encoding)'))
    fileOpen = @($false,('$stream='+$open+';'+$read))
    fileStream = @($false,('$stream='+$construct+';'+$read))
    openRead = @($false,('$stream=[System.IO.File]::OpenRead('+$guard+');'+$read))
    rethrow = @($false,('$stream='+$open+';'+$read))
    nestedRethrow = @($false,('trap {throw $_.Exception};$stream='+$open+';'+$read))
    unknownStream = @($false,$read)
    unguarded = @($false,('$stream='+$open.Replace($guard,'$Path')+';'+$read))
    wrongVariable = @($false,('$other='+$open+';'+$read))
    reassigned = @($false,('$stream='+$open+';$stream=$Other;'+$read))
    interveningCommand = @($false,('$stream='+$open+';Invoke-Opaque;'+$read))
    conditional = @($false,('if($flag){$stream='+$open+'};'+$read))
    nestedTry = @($false,('try {$stream='+$open+'} finally {};'+$read))
    alias = @($false,('$stream='+$open+';$alias=$stream;$reader=[IO.StreamReader]::new($alias)'))
    unknownFactory = @($false,('$stream=Get-Stream '+$guard+';'+$read))
    typeAlias = @($false,('$io=[IO.File];$stream=$io::OpenRead('+$guard+');'+$read))
    scopeQualified = @($false,('$script:stream='+$open+';$reader=[IO.StreamReader]::new($script:stream)'))
    compoundAssignment = @($false,('$stream+='+$open+';'+$read))
    pipelineOutput = @($false,('$stream='+$open+'|Select-Object -First 1;'+$read))
    trapped = @($false,('trap {continue};$stream='+$open+';'+$read))
    opaqueTrap = @($false,('trap {Invoke-Opaque;throw $_.Exception};$stream='+$open+';'+$read))
    newObject = @($false,('$stream=New-Object IO.FileStream -ArgumentList '+$guard+';'+$read))
    differentReceiver = @($false,('$stream=[Unknown.IO]::OpenRead('+$guard+');'+$read))
    readOnlyStorage = @($false,('$ErrorActionPreference=''Continue'';Set-Variable -Name stream -Value $Other -Option ReadOnly;$stream='+$open+';'+$read))
    constantStorage = @($false,('$ErrorActionPreference=''Continue'';Set-Variable -Name stream -Value $Other -Option Constant;$stream='+$open+';'+$read))
    transformedStorage = @($false,('[string]$stream=$Other;$stream='+$open+';'+$read))
    failedOpenStaleStorage = @($false,('$ErrorActionPreference=''Continue'';$stream=$Other;$stream='+$open+';'+$read))
  }
  foreach ($name in $cases.Keys) {
    $trap = if ($name -ceq 'rethrow') { 'trap {throw $_.Exception}' } else { '' }
    [IO.File]::WriteAllText($sourcePath,$import+"`n"+$trap+"`nfunction Read-Synthetic { param(`$Path,`$Other,`$flag) "+$cases[$name][1]+' }')
    $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($sourcePath,[ref]$null,[ref]$errors)
    Check ($errors.Count -eq 0) "synthetic source parses $name"
    $census = Get-LedgerReaderCensus -Root $root
    Check ($census.scanned -eq 2 -and $census.total -eq 2) "complete inventory $name"
    $rows = @($census.rows | Where-Object { $_.path -ceq 'reader.ps1' -and $_.family -ceq 'StreamReader' })
    Check ($rows.Count -eq 1) "actual StreamReader inventory $name"
    Check ([bool]$rows[0].handled -eq $cases[$name][0]) "stream provenance $name handled=$($rows[0].handled)"
  }

  # Execute the actual inline cost constructor, not a lookalike helper. The
  # previous variable-fed pair stays the text/encoding compatibility control.
  $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'cost-harvest.ps1'),[ref]$null,[ref]$null)
  $function = @($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Get-RunFacts'},$true))
  Check ($function.Count -eq 1) 'actual cost function'
  $assignments = @($function[0].Body.EndBlock.Statements | Where-Object {
    $_ -is [Management.Automation.Language.AssignmentStatementAst] -and $_.Left.Extent.Text -cin @('$stream','$reader')
  })
  Check ($assignments.Count -eq 1 -and $assignments[0].Left.Extent.Text -ceq '$reader') 'actual inline constructor assignment'
  $actual = ($assignments | ForEach-Object { $_.Extent.Text }) -join "`n"
  Check ($actual.Contains($guard,[StringComparison]::Ordinal)) 'actual path guard operand retained'
  $native = $actual.Replace($guard,'$Path')
  $probe = Join-Path $root 'probe.ps1'
  $preamble = 'param([string]$Path)'+"`n"+$import+"`n"
  $drain = "`ntry { `$reader.ReadToEnd() } finally { `$reader.Dispose() }"
  $positive = Join-Path $root 'ordinary.txt'
  $bytes = [byte[]]@(0xef,0xbb,0xbf,0x61,0x0d,0x0a,0xff,0x62)
  [IO.File]::WriteAllBytes($positive,$bytes)
  [IO.File]::WriteAllText($probe,$preamble+$native+$drain)
  $expected = & $probe $positive
  $legacy='$stream='+$construct.Replace($guard,'$Path')+';'+$read
  [IO.File]::WriteAllText($probe,$preamble+$legacy+$drain)
  Check ((& $probe $positive) -ceq $expected) 'old variable-fed constructor text/BOM/CRLF/invalidUTF8 equivalent'
  [IO.File]::WriteAllText($probe,$preamble+$actual+$drain)
  Check ((& $probe $positive) -ceq $expected) 'actual cost stream text/BOM/CRLF/invalidUTF8 unchanged'
  $refused = 0; $red = 0
  foreach ($alias in @('dispatch-log.jsonl','DISPATCH-LOG.JSONL','./dispatch-log.jsonl','dispatch-log.jsonl.','dispatch-log.jsonl ','dispatch-log.jsonl:stream','dispatch-log.jsonl.:stream')) {
    $target = Join-Path $root $alias
    [IO.File]::WriteAllBytes($target,$bytes)
    $held = [IO.File]::Open($target,'Open','ReadWrite','None')
    try {
      foreach ($body in @($actual,$native)) {
        [IO.File]::WriteAllText($probe,$preamble+$body+$drain)
        $failure = ''; try { & $probe $target | Out-Null } catch { $failure = $_.Exception.Message }
        if ($body -ceq $actual) {
          Check ($failure -match 'DISPATCH_LEDGER_OWNER_REQUIRED') "actual cost owner refusal $alias"
          $refused++
        } else {
          Check ($failure -notmatch 'DISPATCH_LEDGER_OWNER_REQUIRED' -and $failure -match 'used by another process|sharing violation|Could not open the.*alternate data stream') "actual guard-removal native failure $alias"
          $red++
        }
      }
    } finally { $held.Dispose() }
    Check ([Convert]::ToHexString([IO.File]::ReadAllBytes($target)) -ceq [Convert]::ToHexString($bytes)) "canonical alias unchanged $alias"
  }
  $scorecardPath = Join-Path $PSScriptRoot 'platform-scorecard.ps1'
  $scorecardAst = [Management.Automation.Language.Parser]::ParseFile($scorecardPath,[ref]$null,[ref]$null)
  $ledgerFunction = @($scorecardAst.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Read-ScorecardLedgers'},$true))
  Check ($ledgerFunction.Count -eq 1) 'actual mixed scorecard ledger function'
  $costRead = @($ledgerFunction[0].FindAll({param($n) $n -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Expression.Extent.Text -ceq '[IO.File]' -and $n.Member.Value -ceq 'ReadLines'},$true))
  Check ($costRead.Count -eq 1) 'actual scorecard native cost reader'
  $costGuard = '(dispatch-ledger-reader\Get-NonDispatchLedgerPath -Path (Join-Path $runtime ''cost-ledger.jsonl''))'
  $actualCost = $costRead[0].Extent.Text
  Check ($actualCost.Contains($costGuard,[StringComparison]::Ordinal)) 'actual scorecard cost operand guarded'
  $nativeCost = $actualCost.Replace($costGuard,'(Join-Path $runtime ''cost-ledger.jsonl'')')
  # Only redirect the path construction in the isolated probe. The exact native
  # expression, owner guard and deferred ReadLines enumeration stay production code.
  $costPreamble = 'param([string]$ProbePath)'+"`n"+$import+@'

function Join-Path([string]$Path,[string]$ChildPath) {
  if ($ChildPath -ceq 'cost-ledger.jsonl') { return $ProbePath }
  return Microsoft.PowerShell.Management\Join-Path $Path $ChildPath
}
$runtime=$PSScriptRoot
'@
  [IO.File]::WriteAllText($probe,$costPreamble+"`n@("+$nativeCost+')')
  $nativeLines = @(& $probe $positive)
  [IO.File]::WriteAllText($probe,$costPreamble+"`n@("+$actualCost+')')
  Check ((ConvertTo-Json -Compress -InputObject @(& $probe $positive)) -ceq (ConvertTo-Json -Compress -InputObject $nativeLines)) 'scorecard ReadLines BOM/CRLF/invalidUTF8 unchanged'
  $scorecardRefused=0;$scorecardMutants=0
  foreach ($alias in @('dispatch-log.jsonl','DISPATCH-LOG.JSONL','./dispatch-log.jsonl','dispatch-log.jsonl.','dispatch-log.jsonl ','dispatch-log.jsonl:stream','dispatch-log.jsonl.:stream')) {
    $target=Join-Path $root $alias
    [IO.File]::WriteAllBytes($target,$bytes)
    $held=[IO.File]::Open($target,'Open','ReadWrite','None')
    try {
      foreach ($body in @($actualCost,$nativeCost)) {
        [IO.File]::WriteAllText($probe,$costPreamble+"`n@("+$body+')')
        $failure='';try { & $probe $target | Out-Null } catch { $failure=$_.Exception.Message }
        if ($body -ceq $actualCost) {
          Check ($failure -match 'DISPATCH_LEDGER_OWNER_REQUIRED') "scorecard owner refusal before native acquisition $alias"
          $scorecardRefused++
        } else {
          Check ($failure -notmatch 'DISPATCH_LEDGER_OWNER_REQUIRED' -and $failure -match 'used by another process|sharing violation|Could not open the.*alternate data stream') "scorecard guard-removal native failure $alias"
          $scorecardMutants++
        }
      }
    } finally { $held.Dispose() }
    Check ([Convert]::ToHexString([IO.File]::ReadAllBytes($target)) -ceq [Convert]::ToHexString($bytes)) "scorecard alias untouched $alias"
  }
  foreach ($guarded in @($true,$false)) {
    $body=$ledgerFunction[0].Extent.Text
    if (-not $guarded) { $body=$body.Replace($costGuard,'(Join-Path $runtime ''cost-ledger.jsonl'')') }
    [IO.File]::WriteAllText($sourcePath,$import+"`n"+$body)
    $census=Get-LedgerReaderCensus -Root $root
    $rows=@($census.rows | Where-Object { $_.path -ceq 'reader.ps1' -and $_.family -ceq 'IO.File.ReadLines' })
    Check ($rows.Count -eq 1) "actual scorecard native row guarded=$guarded"
    Check ([bool]$rows[0].handled -eq $guarded) "actual scorecard per-use census proof guarded=$guarded"
    Check (@($census.rows | Where-Object { $_.path -ceq 'reader.ps1' -and $_.family -ceq 'owner-api' -and $_.owner -and $_.handled }).Count -eq 1) "canonical scorecard API retained guarded=$guarded"
  }
  . $scorecardPath -FunctionsOnly
  $script:ScorecardGaps=[Collections.Generic.List[string]]::new()
  [IO.File]::WriteAllText((Join-Path $root '.orchestrator/dispatch-log.jsonl'),'{"kind":"dispatch","issue":101}'+"`n")
  [IO.File]::WriteAllText((Join-Path $root '.orchestrator/cost-ledger.jsonl'),'{"transcript":"same","usd":1}'+"`n"+'{"transcript":"same","usd":2}'+"`n")
  $ledgers=Read-ScorecardLedgers $root
  Check ($ledgers.dispatchComplete -and $ledgers.costComplete -and $ledgers.dispatches.Count -eq 1 -and $ledgers.costs.Count -eq 1 -and $ledgers.costs[0].usd -eq 2 -and $script:ScorecardGaps.Count -eq 0) 'actual scorecard mixed reducers complete with last cost row'
  $released=[IO.File]::Open((Join-Path $root '.orchestrator/cost-ledger.jsonl'),'Open','ReadWrite','None')
  $released.Dispose()
  $scorecardBody=$ledgerFunction[0].Extent.Text
  $lifetimeChecks=0;$disposeMutants=0
  try {
    foreach ($mode in @('actual','disposeRemoval')) {
      if ($mode -ceq 'disposeRemoval') {
        $anchor='$costLines.Dispose()'
        Check ($scorecardBody.Contains($anchor) -and $scorecardBody.IndexOf($anchor) -eq $scorecardBody.LastIndexOf($anchor)) 'one explicit cost iterator disposal mutation anchor'
        . ([scriptblock]::Create($scorecardBody.Replace($anchor,'$null')))
      }
      foreach ($badRow in @('invalid-json','{"usd":1}')) {
        $costPath=Join-Path $root '.orchestrator/cost-ledger.jsonl'
        [IO.File]::WriteAllText($costPath,'{"transcript":"prefix","usd":1}'+"`n"+$badRow+"`n"+'{"transcript":"unread","usd":2}'+"`n")
        $script:ScorecardGaps=[Collections.Generic.List[string]]::new()
        # Exclude finalizer timing from the actual-function postcondition. GC is
        # test cleanup only, after recording/checking the immediate native open.
        [GC]::Collect();[GC]::WaitForPendingFinalizers()
        $noGc=[GC]::TryStartNoGCRegion(64MB)
        Check $noGc 'admit bounded test-only no-GC lifetime observation'
        try {
          $ledgers=Read-ScorecardLedgers $root
          $writable=$false
          try {$writer=[IO.File]::Open($costPath,'Open','ReadWrite','None');$writer.Dispose();$writable=$true} catch [IO.IOException] {}
          Check ($ledgers.dispatchComplete -and -not $ledgers.costComplete -and $ledgers.dispatches.Count -eq 1 -and $ledgers.costs.Count -eq 1 -and $ledgers.costs[0].transcript -ceq 'prefix' -and $script:ScorecardGaps.Count -eq 1 -and $script:ScorecardGaps[0] -ceq 'cost-ledger-unavailable') "actual scorecard partial reducer/named failure gap $mode $badRow"
          Check ($writable -eq ($mode -ceq 'actual')) "scorecard exceptional cost handle release without finalizers $mode $badRow writable=$writable"
          if ($mode -ceq 'actual') {$lifetimeChecks++} else {$disposeMutants++}
        } finally {
          if ($noGc) {[GC]::EndNoGCRegion()}
          [GC]::Collect();[GC]::WaitForPendingFinalizers()
        }
      }
    }
  } finally {. ([scriptblock]::Create($scorecardBody))}
  Write-Output "PASS stream provenance checks=$checks cases=$($cases.Count) actualCostOwnerRefusals=$refused actualGuardRemovalRED=$red scorecardOwnerRefusals=$scorecardRefused scorecardGuardRemovalRED=$scorecardMutants exceptionalCostReleases=$lifetimeChecks disposalRemovalRED=$disposeMutants"
} finally {
  $full = [IO.Path]::GetFullPath($root)
  if ((Split-Path -Parent $full).TrimEnd('\','/') -cne ([IO.Path]::GetFullPath([IO.Path]::GetTempPath())).TrimEnd('\','/') -or
      (Split-Path -Leaf $full) -cnotlike 'ledger-stream-provenance-*') { throw 'unsafe stream provenance cleanup' }
  if (Test-Path -LiteralPath $full) { Remove-Item -LiteralPath $full -Recurse -Force }
}
