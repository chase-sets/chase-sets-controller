$ErrorActionPreference='Stop'
$checks=0
function Check([bool]$Condition,[string]$Message){
  $script:checks++
  if(-not $Condition){throw "ASSERTION FAILED: $Message"}
}
$root=Join-Path ([IO.Path]::GetTempPath()) ('ledger-guard-receipts-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
try {
  Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'dispatch-ledger-reader.psm1') -Destination $root
  $import="Import-Module (Join-Path `$PSScriptRoot 'dispatch-ledger-reader.psm1') -Global -DisableNameChecking"
  $sources=[ordered]@{'fail-closed-guard-evidence.ps1'='$resolvedReceipt';'fail-closed-guard-evidence-aggregate.ps1'='$resolved'}
  $bytes=[byte[]]@(0xef,0xbb,0xbf,0x7b,0x7d,0x0d,0x0a,0xff)
  $positive=Join-Path $root 'ordinary.json';[IO.File]::WriteAllBytes($positive,$bytes)
  $aliases=@('dispatch-log.jsonl','DISPATCH-LOG.JSONL','./dispatch-log.jsonl',
    'dispatch-log.jsonl.','dispatch-log.jsonl ','dispatch-log.jsonl:guard','dispatch-log.jsonl.:guard')
  foreach($name in $sources.Keys){
    $errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $name),[ref]$null,[ref]$errors)
    Check ($errors.Count-eq0) "source parses $name"
    $imports=@($ast.EndBlock.Statements|Where-Object{$_.Extent.Text-ceq$import})
    $reads=@($ast.FindAll({param($n)
      $n -is [Management.Automation.Language.InvokeMemberExpressionAst] -and
      $n.Expression.Extent.Text-ceq'[IO.File]' -and $n.Member.Value-ceq'ReadAllBytes'
    },$true))
    Check ($reads.Count-eq1) "complete native receipt byte-read inventory $name"
    $read=$reads[0];$path=$sources[$name]
    $guard="(dispatch-ledger-reader\Get-NonDispatchLedgerPath -Path $path)"
    $probe=Join-Path $root 'probe.ps1'
    $preamble='param([string]$ProbePath)'+"`n"+$import+"`n"+'$resolvedReceipt=$resolved=$ProbePath'+"`n"
    [IO.File]::WriteAllText($probe,$preamble+$read.Extent.Text)
    $actual=[byte[]](& $probe $positive)
    Check ([Convert]::ToHexString($actual)-ceq[Convert]::ToHexString($bytes)) 'native bytes preserve BOM, CRLF and invalid UTF8 for downstream validation'
    foreach($alias in $aliases){
      $target=Join-Path $root $alias;[IO.File]::WriteAllBytes($target,$bytes)
      $held=[IO.File]::Open($target,'Open','ReadWrite','None')
      try{
        $failure='';try{& $probe $target|Out-Null}catch{$failure=$_.Exception.Message}
        Check ($failure-match'DISPATCH_LEDGER_OWNER_REQUIRED') "owner refusal before actual native read $name/$alias : $failure"
      }finally{$held.Dispose()}
      Check ([Convert]::ToHexString([IO.File]::ReadAllBytes($target))-ceq[Convert]::ToHexString($bytes)) 'rejected alias bytes unchanged'
    }
    Check ($imports.Count-eq1-and$imports[0].Extent.EndOffset-lt$read.Extent.StartOffset) 'literal global non-forcing import dominates native read'
    Check ($read.Arguments.Count-eq1-and$read.Arguments[0].Extent.Text-ceq$guard) 'original byte-read operand wrapped exactly once'
    $removed=$read.Extent.Text.Replace($guard,$path)
    Check ($removed-cne$read.Extent.Text) 'exact guard-removal mutation changes actual read'
    [IO.File]::WriteAllText($probe,$preamble+$removed)
    $target=Join-Path $root 'dispatch-log.jsonl';$held=[IO.File]::Open($target,'Open','ReadWrite','None')
    try{
      $failure='';try{& $probe $target|Out-Null}catch{$failure=$_.Exception.Message}
      Check ($failure-and$failure-notmatch'DISPATCH_LEDGER_OWNER_REQUIRED') 'guard removal reaches actual native sharing failure'
    }finally{$held.Dispose()}
  }
  Write-Output "PASS ledger-reader-guard-receipt-paths checks=$checks native=2 aliases=7 guardRemoval=RED bytePreservation=true"
}finally{
  $full=[IO.Path]::GetFullPath($root)
  if((Split-Path -Parent $full).TrimEnd('\','/')-cne([IO.Path]::GetFullPath([IO.Path]::GetTempPath())).TrimEnd('\','/')-or
    (Split-Path -Leaf $full)-cnotlike'ledger-guard-receipts-*'){throw 'unsafe guard receipt fixture cleanup'}
  Remove-Item -LiteralPath $full -Recurse -Force
}
