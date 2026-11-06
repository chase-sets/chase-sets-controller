param([switch]$WithTrap)
$ErrorActionPreference='Stop'
$script:checks=0
function Check([bool]$Condition,[string]$Message) {
  $script:checks++
  if(-not $Condition){throw "ASSERTION FAILED: $Message"}
}
$root=Join-Path ([IO.Path]::GetTempPath()) ('ledger-heavy-paths-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
try {
  $entry=Join-Path $PSScriptRoot 'invoke-heavy-verifier.ps1'
  $tokens=$null;$errors=$null
  $ast=[Management.Automation.Language.Parser]::ParseFile($entry,[ref]$tokens,[ref]$errors)
  Check ($errors.Count -eq 0) 'heavy entry parses'
  $trapSource=''
  if($WithTrap) {
    $traps=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.TrapStatementAst]},$true))
    Check ($traps.Count -eq 0) 'heavy runtime has no resumable script trap'
    $boundary=@($ast.EndBlock.Statements|Where-Object {$_ -is [Management.Automation.Language.TryStatementAst]})
    Check ($boundary.Count -eq 1 -and $boundary[0].CatchClauses.Count -eq 1) 'one outer heavy catch boundary'
    $trapSource='trap '+$boundary[0].CatchClauses[0].Body.Extent.Text
  }
  $import="Import-Module (Join-Path `$PSScriptRoot 'dispatch-ledger-reader.psm1') -Force -DisableNameChecking"
  $imports=@($ast.EndBlock.Statements|Where-Object {$_.Extent.Text -ceq $import})
  Check ($imports.Count -eq 1) 'literal unconditional owner import'
  $reads=@($ast.FindAll({param($node)
    ($node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ceq 'Get-Content') -or
    ($node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and
      $node.Expression.Extent.Text -ceq '[IO.File]' -and
      ($node.Member.Value -in @('ReadAllBytes','ReadAllText') -or
       ($node.Member.Value -ceq 'Open' -and $node.Arguments[2].Extent.Text -ceq '[IO.FileAccess]::Read')))
  },$true))
  $paths=@('$Path','$Path','$claimPath','$path','$fixturePath','$declarationPath','$candidate','$full',
    '$path','$Evaluation.selectedPath','$path','$path','$nativeRequestFull','$Path','$PSCommandPath',
    '$RecordPath','$Path','$queueRecoveryPath','$stage','$stage','$proofPath','$stage','$ClaimPath',
    '$diagnosticScriptFull','$manifestFile.FullName','$diagnosticResultPath','$workspaceDbStagePath','$receiptPath')
  Check ($reads.Count -eq $paths.Count) '28 path-based reads; writers, stream handles and embedded code excluded'
  Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'dispatch-ledger-reader.psm1') -Destination $root
  $positive=Join-Path $root 'synthetic.json'
  [IO.File]::WriteAllText($positive,'{"schemaVersion":4,"synthetic":true}')
  $expected=[IO.File]::ReadAllBytes($positive)
  $aliases=@('dispatch-log.jsonl','DISPATCH-LOG.JSONL','./dispatch-log.jsonl','dispatch-log.jsonl.',
    'dispatch-log.jsonl ','dispatch-log.jsonl:heavy','dispatch-log.jsonl.:heavy')
  for($index=0;$index -lt $reads.Count;$index++) {
    $read=$reads[$index]
    $guard="(dispatch-ledger-reader\Get-NonDispatchLedgerPath -Path $($paths[$index]))"
    Check ($read.Extent.Text.Contains($guard,[StringComparison]::Ordinal)) "exact original path guarded $index"
    Check ($imports[0].Extent.EndOffset -lt $read.Extent.StartOffset) "import precedes read $index"
    $probe=Join-Path $root 'probe.ps1'
    $bindings='$Path=$claimPath=$path=$fixturePath=$declarationPath=$candidate=$full=$nativeRequestFull=$PSCommandPath=$RecordPath=$queueRecoveryPath=$stage=$proofPath=$ClaimPath=$diagnosticScriptFull=$diagnosticResultPath=$workspaceDbStagePath=$receiptPath=$ProbePath; $Evaluation=@{selectedPath=$ProbePath}; $manifestFile=[pscustomobject]@{FullName=$ProbePath}; $share=[IO.FileShare]::Read -bor [IO.FileShare]::Delete'
    if($WithTrap) {$bindings+='; $isManifestReplay=$isNativeDb=$isAttachedAdmission=$isControllerSlot=$isHostVerifier=$isControllerHostHeavyVerifier=$false'}
    [IO.File]::WriteAllText($probe,('param([string]$ProbePath)'+"`n"+$import+"`n"+$trapSource+"`n"+$bindings+"`n"+$read.Extent.Text))
    $result=& $probe $positive
    try {
      if($read -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $read.Member.Value -ceq 'Open') {
        Check ($result.CanRead -and -not $result.CanWrite -and $result.Length -eq $expected.Length) "native read-only stream $index"
        if($index -in @(0,1,2,22,23)) {
          $blocked=$false
          try {$other=[IO.File]::Open($positive,'Open','Write','ReadWrite');$other.Dispose()}catch{$blocked=$true}
          Check $blocked "source/pin still denies writes $index"
        } else {
          $other=[IO.File]::Open($positive,'Open','Write',([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
          $other.Dispose()
          Check $true "snapshot/queue read retains writable sharing $index"
        }
      } elseif($read -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $read.Member.Value -ceq 'ReadAllBytes') {
        Check ([Convert]::ToHexString([byte[]]$result) -ceq [Convert]::ToHexString($expected)) "native bytes preserved $index"
      } else {
        Check ($result -ceq '{"schemaVersion":4,"synthetic":true}') "native text preserved $index"
      }
    } finally {if($result -is [IDisposable]){$result.Dispose()}}
    foreach($alias in $aliases) {
      $target=Join-Path $root $alias
      [IO.File]::WriteAllBytes($target,$expected)
      $held=[IO.File]::Open($target,'Open','ReadWrite','None')
      try {
        $failure=''
        try {& $probe $target|Out-Null}catch{$failure=$_.Exception.Message}
        Check ($failure -match 'DISPATCH_LEDGER_OWNER_REQUIRED') "owner refusal before I/O $index/$alias : $failure"
      } finally {$held.Dispose()}
      Check ([Convert]::ToHexString([IO.File]::ReadAllBytes($target)) -ceq [Convert]::ToHexString($expected)) "alias bytes untouched $index/$alias"
    }
    # Removing the exact guard must expose the native sharing failure, not a
    # false owner rejection caused by the fixture itself.
    $mutant=$read.Extent.Text.Replace($guard,$paths[$index])
    Check ($mutant -cne $read.Extent.Text) "guard-removal mutation changes read $index"
    [IO.File]::WriteAllText($probe,('param([string]$ProbePath)'+"`n"+$import+"`n"+$trapSource+"`n"+$bindings+"`n"+$mutant))
    $canonical=Join-Path $root 'dispatch-log.jsonl'
    $held=[IO.File]::Open($canonical,'Open','ReadWrite','None')
    try {
      $failure=''
      try {& $probe $canonical|Out-Null}catch{$failure=$_.Exception.Message}
      Check ($failure -and $failure -notmatch 'DISPATCH_LEDGER_OWNER_REQUIRED') "guard-removal mutant loses owner refusal $index"
    } finally {$held.Dispose()}
  }

  Import-Module (Join-Path $PSScriptRoot 'dispatch-ledger-reader.psm1') -Force -DisableNameChecking
  foreach($name in @('Test-SamePath','Test-SafeDirectory','Test-SafeFile','Read-NativeJson','Get-OwnerSnapshot',
    'Get-QueueSha256','Read-QueueContent','Get-GitBlobId','Test-ControllerFixtureSourceBytes')) {
    $function=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$true))
    Check ($function.Count -eq 1) "one actual function $name"
    . ([scriptblock]::Create($function[0].Extent.Text))
  }
  $lockPath=Join-Path $root 'verify-lock.d';[void][IO.Directory]::CreateDirectory($lockPath)
  $ownerPath=Join-Path $lockPath 'owner.json'
  [IO.File]::WriteAllBytes($ownerPath,$expected)
  $snapshot=Get-OwnerSnapshot
  Check ($snapshot.Raw -ceq [Text.Encoding]::UTF8.GetString($expected) -and $snapshot.Record.synthetic) 'actual owner snapshot body and BOM-aware decoder'
  $snapshotFunction=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Get-OwnerSnapshot'},$true))[0]
  $inline='$reader = [IO.StreamReader]::new([IO.MemoryStream]::new($bytes, $false), [Text.Encoding]::UTF8, $true)'
  Check ($snapshotFunction.Extent.Text.Contains($inline,[StringComparison]::Ordinal)) 'actual owner snapshot directly constructs data-only decoder'
  $legacy=$snapshotFunction.Extent.Text.Replace('function Get-OwnerSnapshot(', 'function Get-LegacyOwnerSnapshot(').Replace($inline,
    '$buffer = [IO.MemoryStream]::new($bytes, $false); $reader = [IO.StreamReader]::new($buffer, [Text.Encoding]::UTF8, $true)')
  . ([scriptblock]::Create($legacy))
  $text="{`r`n  `"schemaVersion`":4,`"synthetic`":true,`"text`":`"caf$([char]0xe9)`"`r`n}"
  $encodings=@([Text.UTF8Encoding]::new($false),[Text.UTF8Encoding]::new($true),
    [Text.UnicodeEncoding]::new($false,$true),[Text.UnicodeEncoding]::new($true,$true),
    [Text.UTF32Encoding]::new($false,$true),[Text.UTF32Encoding]::new($true,$true))
  foreach($encoding in $encodings) {
    foreach($schema in @(4,6)) {
      $content=$text.Replace('"schemaVersion":4',('"schemaVersion":'+$schema))
      [IO.File]::WriteAllBytes($ownerPath,([byte[]]($encoding.GetPreamble()+$encoding.GetBytes($content))))
      $before=Get-LegacyOwnerSnapshot; $after=Get-OwnerSnapshot
      Check (($null -eq $before) -eq ($null -eq $after)) "owner snapshot refusal unchanged $($encoding.CodePage)/$schema"
      Check (($before|ConvertTo-Json -Depth 10 -Compress) -ceq ($after|ConvertTo-Json -Depth 10 -Compress)) "owner snapshot raw/record encoding unchanged $($encoding.CodePage)/$schema"
    }
  }
  $invalid=[Text.Encoding]::UTF8.GetBytes('{"schemaVersion":4,"text":"x"}')
  $invalid[$invalid.Length-3]=0xff
  foreach($schema in @(4,6)) {
    if($schema -eq 6){$invalid[17]=[byte][char]'6'}
    [IO.File]::WriteAllBytes($ownerPath,$invalid)
    $before=Get-LegacyOwnerSnapshot; $after=Get-OwnerSnapshot
    Check (($before|ConvertTo-Json -Depth 10 -Compress) -ceq ($after|ConvertTo-Json -Depth 10 -Compress)) "owner snapshot invalid UTF8 behavior unchanged schema $schema"
    Check (($schema -eq 4 -and $null -ne $after) -or ($schema -eq 6 -and $null -eq $after)) "legacy replacement/schema6 strict refusal retained $schema"
  }
  $queueMaximumBytes=65536
  $queue=Read-QueueContent $positive
  Check ($queue.Size -eq $expected.Length -and $queue.Hash -ceq (Get-QueueSha256 $expected) -and
    [Convert]::ToHexString($queue.Bytes) -ceq [Convert]::ToHexString($expected)) 'actual queue body preserves hash, bytes and bounds'
  $queueMaximumBytes=1
  $queue=Read-QueueContent $positive
  Check ($null -eq $queue.Bytes -and $queue.Size -eq $expected.Length) 'actual oversized queue body still hashes without allocating payload'
  $blob=Get-GitBlobId $expected
  Check (Test-ControllerFixtureSourceBytes $positive $blob) 'actual tracked source body matches git blob'
  Check (-not (Test-ControllerFixtureSourceBytes $positive ('0'*40))) 'actual tracked source body rejects changed blob'
  Write-Output "PASS ledger-reader-heavy-paths checks=$script:checks reads=$($reads.Count)"
} finally {
  $resolved=[IO.Path]::GetFullPath($root)
  if((Split-Path -Parent $resolved).TrimEnd('\','/') -cne ([IO.Path]::GetFullPath([IO.Path]::GetTempPath())).TrimEnd('\','/') -or
    (Split-Path -Leaf $resolved) -notlike 'ledger-heavy-paths-*'){throw 'unsafe heavy fixture cleanup'}
  Remove-Item -LiteralPath $resolved -Recurse -Force
}
