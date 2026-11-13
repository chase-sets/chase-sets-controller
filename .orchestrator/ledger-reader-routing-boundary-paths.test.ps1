$ErrorActionPreference='Stop'
$checks=0
function Check([bool]$Condition,[string]$Message) {
  $script:checks++
  if(-not $Condition){throw "ASSERTION FAILED: $Message"}
}
$root=Join-Path ([IO.Path]::GetTempPath()) ('ledger-routing-boundary-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
try {
  Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'dispatch-ledger-reader.psm1') -Destination $root
  $import="Import-Module (Join-Path `$PSScriptRoot 'dispatch-ledger-reader.psm1') -Global -DisableNameChecking"
  $sources=[ordered]@{'routing-data.ps1'=@('$Path','$path');'codex-launch-boundary.psm1'=@('$LiteralPath','$generatedPath','$fixturePath')}
  $payload='{"synthetic":"non-dispatch"}'
  $positive=Join-Path $root 'ordinary.json';[IO.File]::WriteAllText($positive,$payload,[Text.UTF8Encoding]::new($false))
  $bytes=[IO.File]::ReadAllBytes($positive)
  $aliases=@('dispatch-log.jsonl','DISPATCH-LOG.JSONL','./dispatch-log.jsonl','dispatch-log.jsonl.',
    'dispatch-log.jsonl ','dispatch-log.jsonl:boundary','dispatch-log.jsonl.:boundary')
  $total=0
  foreach($name in $sources.Keys) {
    $errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $name),[ref]$null,[ref]$errors)
    Check ($errors.Count -eq 0) "source parses $name"
    $imports=@($ast.EndBlock.Statements|Where-Object {$_.Extent.Text -ceq $import})
    $reads=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and
      $node.Expression.Extent.Text -ceq '[IO.File]' -and $node.Member.Value -cin @('Open','ReadAllText','ReadAllBytes')},$true))
    Check ($reads.Count -eq $sources[$name].Count) "complete native read inventory $name"
    for($i=0;$i -lt $reads.Count;$i++) {
      $total++;$read=$reads[$i];$path=$sources[$name][$i]
      $guard="(dispatch-ledger-reader\Get-NonDispatchLedgerPath -Path $path)"
      $probe=Join-Path $root 'probe.ps1'
      $preamble='param([string]$ProbePath)'+"`n"+$import+"`n"+'$Path=$LiteralPath=$generatedPath=$fixturePath=$ProbePath'+"`n"
      [IO.File]::WriteAllText($probe,$preamble+$read.Extent.Text)
      $value=& $probe $positive
      if($read.Member.Value -ceq 'Open') {
        try {
          $actual=[byte[]]::new($bytes.Length)
          Check ($value -is [IO.FileStream] -and $value.CanRead -and -not $value.CanWrite -and
            $value.Read($actual,0,$actual.Length) -eq $actual.Length -and [Convert]::ToHexString($actual) -ceq [Convert]::ToHexString($bytes)) 'original read-only PE stream overload returns exact bytes'
        } finally {if($value -is [IDisposable]){$value.Dispose()}}
        Check ($read.Arguments.Count -eq 4 -and $read.Arguments[1].Extent.Text -ceq '[IO.FileMode]::Open' -and
          $read.Arguments[2].Extent.Text -ceq '[IO.FileAccess]::Read' -and $read.Arguments[3].Extent.Text -ceq '[IO.FileShare]::ReadWrite') 'PE mode/access/sharing unchanged'
      } elseif($read.Member.Value -ceq 'ReadAllBytes') {
        Check ([Convert]::ToHexString([byte[]]$value) -ceq [Convert]::ToHexString($bytes)) 'original byte read returns exact native bytes'
      } else {Check ($value -ceq $payload) 'original text read returns exact payload'}
      foreach($alias in $aliases) {
        $target=Join-Path $root $alias;[IO.File]::WriteAllBytes($target,$bytes)
        $held=[IO.File]::Open($target,'Open','ReadWrite','None')
        try {
          $failure='';try{& $probe $target|Out-Null}catch{$failure=$_.Exception.Message}
          Check ($failure -match 'DISPATCH_LEDGER_OWNER_REQUIRED') "refusal before real native read $name/$i/$alias : $failure"
        } finally {$held.Dispose()}
        Check ([Convert]::ToHexString([IO.File]::ReadAllBytes($target)) -ceq [Convert]::ToHexString($bytes)) 'held alias exact bytes unchanged'
      }
      Check ($imports.Count -eq 1 -and $imports[0].Extent.EndOffset -lt $read.Extent.StartOffset) 'literal non-forcing import precedes native expression'
      Check ($read.Arguments[0].Extent.Text -ceq $guard) 'guard covers original first operand, not the native API'
      $removed=$read.Extent.Text.Replace($guard,$path)
      Check ($removed -cne $read.Extent.Text) 'exact guard-removal mutant changes operand'
      [IO.File]::WriteAllText($probe,$preamble+$removed)
      $target=Join-Path $root 'dispatch-log.jsonl';$held=[IO.File]::Open($target,'Open','ReadWrite','None')
      try {
        $failure='';try{& $probe $target|Out-Null}catch{$failure=$_.Exception.Message}
        Check ($failure -and $failure -notmatch 'DISPATCH_LEDGER_OWNER_REQUIRED') 'guard removal reaches genuine sharing failure'
      } finally {$held.Dispose()}
    }
  }
  Write-Output "PASS ledger-reader-routing-boundary-paths checks=$checks native=$total aliases=7 guardRemoval=RED"
} finally {
  $full=[IO.Path]::GetFullPath($root)
  if((Split-Path -Parent $full).TrimEnd('\','/') -cne ([IO.Path]::GetFullPath([IO.Path]::GetTempPath())).TrimEnd('\','/') -or
    (Split-Path -Leaf $full) -cnotlike 'ledger-routing-boundary-*'){throw 'unsafe routing boundary fixture cleanup'}
  Remove-Item -LiteralPath $full -Recurse -Force
}
