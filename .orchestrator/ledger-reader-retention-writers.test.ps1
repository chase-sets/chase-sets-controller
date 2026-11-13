$ErrorActionPreference='Stop'
$script:checks=0
function Check([bool]$Condition,[string]$Message) {
  $script:checks++
  if(-not $Condition){throw "ASSERTION FAILED: $Message"}
}
Import-Module (Join-Path $PSScriptRoot 'ledger-reader-census.psm1') -Force
$root=Join-Path ([IO.Path]::GetTempPath()) ('ledger-retention-writers-'+[guid]::NewGuid().ToString('N'))
try {
  $runtime=Join-Path $root '.orchestrator'
  [void][IO.Directory]::CreateDirectory($runtime)
  $entry=Join-Path $PSScriptRoot 'runtime-retention.ps1'
  $source=[IO.File]::ReadAllText($entry)
  $tokens=$null;$errors=$null
  $ast=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors)
  Check ($errors.Count -eq 0) 'actual retention source parses'
  $opens=@($ast.FindAll({param($node)
    $node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and
      $node.Expression.Extent.Text -ceq '[IO.File]' -and $node.Member.Value -ceq 'Open' -and
      $node.Arguments[0].Extent.Text -cin @('$Path',"(`$stem+'.manifest.json.partial')")
  },$true))
  Check ($opens.Count -eq 2) 'exact two production writer operands, independent of mode/access'
  Copy-Item -LiteralPath $entry -Destination $runtime
  Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'dispatch-ledger-reader.psm1') -Destination $runtime
  & git -C $root init -q
  Check ($LASTEXITCODE -eq 0) 'synthetic inventory initialized'
  & git -C $root add .orchestrator
  Check ($LASTEXITCODE -eq 0) 'actual retention and owner tracked'
  & git -C $root -c user.name=Synthetic -c user.email=synthetic@example.invalid commit -qm retention-writers
  Check ($LASTEXITCODE -eq 0) 'synthetic inventory has census HEAD'
  $census=Get-LedgerReaderCensus -Root $root
  Check ($census.total -eq 2 -and $census.scanned -eq 2) 'small actual tracked inventory'
  foreach($open in $opens) {
    $rows=@($census.rows|Where-Object {$_.path -ceq '.orchestrator/runtime-retention.ps1' -and $_.line -eq $open.Extent.StartLineNumber -and $_.family -ceq 'IO.File.Open'})
    Check ($rows.Count -eq 1) 'one actual census row per production open'
    Write-Output ("RETENTION-WRITER line=$($rows[0].line) role=$($rows[0].role) authority=$($rows[0].authority) handled=$($rows[0].handled)")
  }
  foreach($open in $opens) {
    $row=@($census.rows|Where-Object {$_.path -ceq '.orchestrator/runtime-retention.ps1' -and $_.line -eq $open.Extent.StartLineNumber -and $_.family -ceq 'IO.File.Open'})[0]
    Check ($row.role -ceq 'writer' -and -not $row.handled -and -not $row.test -and -not $row.owner -and
      $row.authority -ceq 'indeterminate') 'actual writers preserve instance-derived and concatenation uncertainty, without owner or test exemption'
    $enforced=@($census.violations|Where-Object {$_.path -ceq $row.path -and $_.line -eq $row.line -and $_.family -ceq $row.family -and $_.role -ceq 'writer' -and -not $_.handled})
    Check ($enforced.Count -eq 0 -and -not $row.dispatchInput -and -not $row.violationReason) 'uncertain write-only input remains diagnostic without dispatch provenance'
    Check ($open.Arguments.Count -eq 4 -and $open.Arguments[1].Extent.Text -ceq '[IO.FileMode]::CreateNew' -and
      $open.Arguments[2].Extent.Text -ceq '[IO.FileAccess]::Write' -and $open.Arguments[3].Extent.Text -ceq '[IO.FileShare]::None') 'explicit exclusive CreateNew/write-only enums'

    $operand=$open.Arguments[0]
    # The same writer shape must still refuse a mixed dispatch/unknown input.
    $dispatchSource=$source.Remove($operand.Extent.StartOffset,$operand.Extent.Text.Length).Insert(
      $operand.Extent.StartOffset,"('dispatch-log.jsonl'+$($operand.Extent.Text))")
    $dispatch=Get-LedgerReaderCensus -Root $root -SourceOverride @{'.orchestrator/runtime-retention.ps1'=$dispatchSource}
    $dispatchRows=@($dispatch.violations|Where-Object {$_.path -ceq $row.path -and $_.line -eq $row.line -and $_.family -ceq $row.family})
    Check ($dispatchRows.Count -eq 1 -and $dispatchRows[0].role -ceq 'writer' -and -not $dispatchRows[0].handled -and
      $dispatchRows[0].dispatchInput -and $dispatchRows[0].violationReason -ceq 'dispatch-provenance') 'mixed dispatch writer input remains enforced at each actual site'
    $literalSource=$source.Remove($operand.Extent.StartOffset,$operand.Extent.Text.Length).Insert($operand.Extent.StartOffset,"'ordinary.zip.partial'")
    $literal=Get-LedgerReaderCensus -Root $root -SourceOverride @{'.orchestrator/runtime-retention.ps1'=$literalSource}
    $positive=@($literal.rows|Where-Object {$_.path -ceq $row.path -and $_.line -eq $row.line -and $_.family -ceq $row.family})
    Check ($positive.Count -eq 1 -and $positive[0].role -ceq 'writer' -and $positive[0].handled -and $positive[0].authority -ceq 'non-ledger' -and -not $positive[0].owner -and -not $positive[0].test) 'literal operand writer remains a positive at each actual native site'

    # Compare the AST-derived native call with its previous string-enum form.
    $legacy=$open.Extent.Text
    foreach($index in @(3,2,1)) {
      $argument=$open.Arguments[$index]
      $legacy=$legacy.Remove($argument.Extent.StartOffset-$open.Extent.StartOffset,$argument.Extent.Text.Length).Insert(
        $argument.Extent.StartOffset-$open.Extent.StartOffset,"'$($argument.Member.Value)'")
    }
    foreach($body in @($legacy,$open.Extent.Text)) {
      $Path=Join-Path $root ([guid]::NewGuid().ToString('N')+'.zip.partial')
      $stem=Join-Path $root ([guid]::NewGuid().ToString('N'))
      $target=if($open.Arguments[0].Extent.Text -ceq '$Path'){$Path}else{$stem+'.manifest.json.partial'}
      $invoke=[scriptblock]::Create($body)
      $s=& $invoke
      $bytes=[byte[]]@(0,1,13,10,127,255)
      try {
        Check ($s.CanWrite -and -not $s.CanRead -and $s.Length -eq 0) 'native fresh write-only stream'
        $readRefused=$false;try {$null=$s.ReadByte()}catch{$readRefused=$_.Exception.GetBaseException() -is [NotSupportedException]}
        Check $readRefused 'native stream cannot read'
        foreach($access in @([IO.FileAccess]::Read,[IO.FileAccess]::Write)) {
          $blocked=$false
          try {$other=[IO.File]::Open($target,[IO.FileMode]::Open,$access,[IO.FileShare]::ReadWrite);$other.Dispose()}
          catch {$blocked=$_.Exception.GetBaseException() -is [IO.IOException]}
          Check $blocked "native exclusive share denies $access"
        }
        $s.Write($bytes,0,$bytes.Length);$s.Flush($true)
      } finally {$s.Dispose()}
      Check ([Convert]::ToHexString([IO.File]::ReadAllBytes($target)) -ceq [Convert]::ToHexString($bytes)) 'native durable flush preserves exact bytes'
      $refused=$false
      try {$unexpected=& $invoke;$unexpected.Dispose()}catch{$refused=$_.Exception.GetBaseException() -is [IO.IOException]}
      Check $refused 'native CreateNew refuses existing file'
      Check ([Convert]::ToHexString([IO.File]::ReadAllBytes($target)) -ceq [Convert]::ToHexString($bytes)) 'existing file not overwritten'
    }

    # Change only these two enum operands in the complete actual source. No
    # filename exemption may hide a future read at either writer location.
    $mutant=$source
    foreach($index in @(2,1)) {
      $argument=$open.Arguments[$index]
      $replacement=if($index -eq 2){'[IO.FileAccess]::Read'}else{'[IO.FileMode]::Open'}
      $mutant=$mutant.Remove($argument.Extent.StartOffset,$argument.Extent.Text.Length).Insert($argument.Extent.StartOffset,$replacement)
    }
    $changed=Get-LedgerReaderCensus -Root $root -SourceOverride @{'.orchestrator/runtime-retention.ps1'=$mutant}
    $readers=@($changed.violations|Where-Object {$_.path -ceq '.orchestrator/runtime-retention.ps1' -and $_.line -eq $open.Extent.StartLineNumber -and $_.family -ceq 'IO.File.Open'})
    Check ($readers.Count -eq 1 -and $readers[0].role -ceq 'reader' -and -not $readers[0].handled -and -not $readers[0].test -and -not $readers[0].owner) 'Open+Read mutation remains an unhandled actual census reader'
    Write-Output "RETENTION-WRITER mutation line=$($open.Extent.StartLineNumber) role=$($readers[0].role) handled=$($readers[0].handled)"
  }

  Import-Module (Join-Path $runtime 'dispatch-ledger-reader.psm1') -Force -DisableNameChecking
  $writer=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Write-RetentionZip'},$true)
  . ([scriptblock]::Create($writer.Extent.Text))
  $zipPath=Join-Path $root 'actual.zip'
  $payload=[byte[]]@(0,255,13,10,65)
  Write-RetentionZip $zipPath @([pscustomobject]@{path='synthetic.bin';link=$true;bytes=$payload})
  $zip=[IO.Compression.ZipFile]::OpenRead($zipPath)
  try {
    Check ($zip.Entries.Count -eq 1 -and $zip.Entries[0].FullName -ceq 'synthetic.bin') 'actual ZIP writer retains entry'
    $input=$zip.Entries[0].Open();$buffer=[IO.MemoryStream]::new()
    try {$input.CopyTo($buffer);Check ([Convert]::ToHexString($buffer.ToArray()) -ceq [Convert]::ToHexString($payload)) 'actual ZIP writer retains exact bytes'}
    finally {$input.Dispose();$buffer.Dispose()}
  } finally {$zip.Dispose()}
  $manifestOpen=$opens[1]
  $flush=$ast.Find({param($node) $node -is [Management.Automation.Language.TryStatementAst] -and $node.Extent.StartOffset -gt $manifestOpen.Extent.EndOffset},$true)
  Check ($flush.Extent.Text -ceq 'try{$s.Write($bytes,0,$bytes.Length);$s.Flush($true)}finally{$s.Dispose()}') 'actual manifest write/Flush(true)/dispose body unchanged'
  $stem=Join-Path $root 'actual';$bytes=[Text.Encoding]::UTF8.GetBytes('{"schema":"synthetic","files":[]}')
  & ([scriptblock]::Create('$s='+$manifestOpen.Extent.Text+';'+$flush.Extent.Text))
  Check ([Convert]::ToHexString([IO.File]::ReadAllBytes($stem+'.manifest.json.partial')) -ceq [Convert]::ToHexString($bytes)) 'actual manifest body flushes exact bytes'
  Write-Output "PASS ledger-reader-retention-writers checks=$script:checks writers=2 legacyNative=2 explicitNative=2 readerMutations=2 actualZip=true actualManifest=true"
} finally {
  $full=[IO.Path]::GetFullPath($root)
  if((Split-Path -Parent $full).TrimEnd('\','/') -cne ([IO.Path]::GetFullPath([IO.Path]::GetTempPath())).TrimEnd('\','/') -or
    (Split-Path -Leaf $full) -cnotlike 'ledger-retention-writers-*'){throw 'unsafe retention writer fixture cleanup'}
  if(Test-Path -LiteralPath $full){Remove-Item -LiteralPath $full -Recurse -Force}
}
