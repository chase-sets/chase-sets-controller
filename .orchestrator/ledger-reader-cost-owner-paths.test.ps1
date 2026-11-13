$ErrorActionPreference='Stop'
$script:checks=0
function Check([bool]$Condition,[string]$Message) {
  $script:checks++
  if(-not $Condition){throw "ASSERTION FAILED: $Message"}
}
$root=Join-Path ([IO.Path]::GetTempPath()) ('ledger-cost-owner-paths-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
try {
  Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'dispatch-ledger-reader.psm1') -Destination $root
  $import="Import-Module (Join-Path `$PSScriptRoot 'dispatch-ledger-reader.psm1') -DisableNameChecking"
  $sources=[ordered]@{
    'cost-harvest.ps1'=@{paths=@('$Ledger','$Path','$Ledger');bindings='$Ledger=$Path=$ProbePath'}
    'dispatch-ownership.ps1'=@{paths=@('$RecordPath','$headNamePath','$file','$TranscriptPath');bindings='$RecordPath=$headNamePath=$file=$TranscriptPath=$ProbePath'}
    'landed-integration-consume.ps1'=@{paths=@('$acceptPath','$path.FullName');bindings='$acceptPath=$ProbePath;$path=[pscustomobject]@{FullName=$ProbePath}'}
  }
  $payload='{"evidence":"non-dispatch","value":12}'
  $positive=Join-Path $root 'ordinary.jsonl'
  [IO.File]::WriteAllText($positive,$payload,[Text.UTF8Encoding]::new($false))
  $bytes=[IO.File]::ReadAllBytes($positive)
  $aliases=@('dispatch-log.jsonl','DISPATCH-LOG.JSONL','./dispatch-log.jsonl',
    'dispatch-log.jsonl.','dispatch-log.jsonl ','dispatch-log.jsonl:dispatch','dispatch-log.jsonl.:dispatch')
  $probe=Join-Path $root 'probe.ps1'
  $total=0
  foreach($name in $sources.Keys) {
    $errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $name),[ref]$null,[ref]$errors)
    Check ($errors.Count -eq 0) "production parses $name"
    $imports=@($ast.EndBlock.Statements|Where-Object {$_.Extent.Text -ceq $import})
    $reads=@($ast.FindAll({param($node)
      ($node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ceq 'Get-Content') -or
      ($node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and
        (($node.Expression.Extent.Text -ceq '[IO.File]' -and ($node.Member.Value -ceq 'ReadAllText' -or
          ($node.Member.Value -ceq 'Open' -and $node.Arguments[1].Extent.Text -ceq '[IO.FileMode]::Open'))) -or
         ($node.Expression.Extent.Text -ceq '[System.IO.FileStream]' -and $node.Member.Value -ceq 'new')))
    },$true))
    Check ($reads.Count -eq $sources[$name].paths.Count) "complete native path inventory $name"
    for($index=0;$index -lt $reads.Count;$index++) {
      $total++
      $read=$reads[$index];$path=$sources[$name].paths[$index]
      $guard="(dispatch-ledger-reader\Get-NonDispatchLedgerPath -Path $path)"
      $preamble='param([string]$ProbePath)'+"`n"+$import+"`n"+$sources[$name].bindings+"`n"
      [IO.File]::WriteAllText($probe,$preamble+$read.Extent.Text)
      $result=& $probe $positive
      $isStream=$read -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $read.Member.Value -cin @('Open','new')
      if($isStream) {
        try {
          Check ($result -is [IO.FileStream] -and $result.CanRead -and -not $result.CanWrite) "read-only native stream $name/$index"
          $actual=[byte[]]::new($bytes.Length)
          Check ($result.Read($actual,0,$actual.Length) -eq $actual.Length -and [Convert]::ToHexString($actual) -ceq [Convert]::ToHexString($bytes)) "exact native stream bytes $name/$index"
          Check ($result.ReadByte() -eq -1) 'native stream remains at exact EOF'
        } finally {if($result -is [IDisposable]){$result.Dispose()}}
      } else {Check ($result -ceq $payload) "exact native text $name/$index"}
      foreach($alias in $aliases) {
        $target=Join-Path $root $alias
        [IO.File]::WriteAllBytes($target,$bytes)
        $held=[IO.File]::Open($target,'Open','ReadWrite','None')
        try {
          $failure=''
          try {& $probe $target|Out-Null}catch{$failure=$_.Exception.Message}
          Check ($failure -match 'DISPATCH_LEDGER_OWNER_REQUIRED') "owner refusal before native I/O $name/$index/$alias : $failure"
        } finally {$held.Dispose()}
        Check ([Convert]::ToHexString([IO.File]::ReadAllBytes($target)) -ceq [Convert]::ToHexString($bytes)) 'alias bytes untouched'
      }
      Check ($imports.Count -eq 1 -and $imports[0].Extent.EndOffset -lt $read.Extent.StartOffset) "literal non-forcing import precedes $name/$index"
      $original=$read.Extent.Text.Replace($guard,$path)
      Check ($original -cne $read.Extent.Text) 'exact guard removal changes native operand'
      $operand=if($read -is [Management.Automation.Language.CommandAst]){$read.CommandElements[2]}else{$read.Arguments[0]}
      Check ($operand.Extent.Text -ceq $guard) 'guard covers the original first path operand only'
      [IO.File]::WriteAllText($probe,$preamble+$original)
      $canonical=Join-Path $root 'dispatch-log.jsonl'
      $held=[IO.File]::Open($canonical,'Open','ReadWrite','None')
      try {
        $Error.Clear();$failure=''
        try {& $probe $canonical 2>$null|Out-Null}catch{$failure=$_.Exception.Message}
        if(-not $failure -and $Error.Count){$failure=$Error[0].Exception.Message}
        Check ($failure -and $failure -notmatch 'DISPATCH_LEDGER_OWNER_REQUIRED') "guard removal exposes native sharing failure $name/$index"
      } finally {$held.Dispose()}
    }
    if($name -ceq 'cost-harvest.ps1') {
      $stream=@($reads|Where-Object {$_.Expression.Extent.Text -ceq '[System.IO.FileStream]'})
      Check ($stream.Count -eq 1 -and $stream[0].Arguments.Count -eq 4) 'cost stream overload preserved'
      Check ($stream[0].Arguments[1].Extent.Text -ceq '[System.IO.FileMode]::Open' -and
        $stream[0].Arguments[2].Extent.Text -ceq '[System.IO.FileAccess]::Read' -and
        $stream[0].Arguments[3].Extent.Text -ceq '[System.IO.FileShare]::ReadWrite') 'cost stream sharing preserved'
      $get=@($reads|Where-Object {$_ -is [Management.Automation.Language.CommandAst]})
      Check ($get[0].Extent.Text.EndsWith(' -ErrorAction SilentlyContinue') -and
        $get[1].Extent.Text -notmatch 'ErrorAction') 'cost content error policies preserved'
    }
    if($name -ceq 'dispatch-ownership.ps1') {
      Check ($reads[0].Arguments.Count -eq 2 -and $reads[0].Arguments[1].Extent.Text -ceq '[Text.Encoding]::UTF8') 'explicit ownership UTF8 overload preserved'
      $stream=$reads[-1]
      Check ($stream.Arguments.Count -eq 4 -and $stream.Arguments[1].Extent.Text -ceq '[IO.FileMode]::Open' -and
        $stream.Arguments[2].Extent.Text -ceq '[IO.FileAccess]::Read' -and
        $stream.Arguments[3].Extent.Text -ceq '[IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete') 'ownership stream overload/sharing preserved'
    }
    if($name -ceq 'landed-integration-consume.ps1') {
      foreach($read in $reads){Check ($read.Extent.Text.EndsWith(' -Raw')) 'consumer literal raw reads preserved'}
      $history=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ceq 'Read-ExactHeadReviewHistory'},$true))
      Check ($history.Count -eq 1 -and $history[0].Extent.Text -ceq 'Read-ExactHeadReviewHistory -Path $HistoryPath') 'consumer history remains owner API'
      $writer=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and
        $node.Expression.Extent.Text -ceq '[IO.File]' -and $node.Member.Value -ceq 'Open'},$true))
      Check ($writer.Count -eq 2 -and
        $writer[0].Extent.Text -ceq '[IO.File]::Open($acceptPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)' -and
        $writer[1].Extent.Text -ceq '[IO.File]::Open($ackPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)') 'both consumer create-only writers unchanged'
    }
  }
  Write-Output "PASS ledger-reader-cost-owner-paths checks=$script:checks native=$total aliases=7 guardRemoval=RED unresolvedHandlesAndCommands=UNKNOWN"
} finally {
  $full=[IO.Path]::GetFullPath($root)
  if((Split-Path -Parent $full).TrimEnd('\','/') -cne ([IO.Path]::GetFullPath([IO.Path]::GetTempPath())).TrimEnd('\','/') -or
    (Split-Path -Leaf $full) -cnotlike 'ledger-cost-owner-paths-*'){throw 'unsafe cost/ownership fixture cleanup'}
  Remove-Item -LiteralPath $full -Recurse -Force
}
