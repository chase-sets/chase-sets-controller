$ErrorActionPreference='Stop'
$checks=0
function Check([bool]$Condition,[string]$Message){
  $script:checks++
  if(-not$Condition){throw "ASSERTION FAILED: $Message"}
}
$root=Join-Path ([IO.Path]::GetTempPath()) ('ledger-reclamation-matrix-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
try {
  Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'dispatch-ledger-reader.psm1') -Destination $root
  $import="Import-Module (Join-Path `$PSScriptRoot 'dispatch-ledger-reader.psm1') -Global -DisableNameChecking"
  $sources=[ordered]@{'cleanup-orphan-worktree-dirs.ps1'='$path';'matrix-refresh.ps1'='$Matrix'}
  $payload='{"synthetic":"non-dispatch"}'
  $positive=Join-Path $root 'ordinary.json'
  [IO.File]::WriteAllText($positive,$payload,[Text.UTF8Encoding]::new($false))
  $bytes=[IO.File]::ReadAllBytes($positive)
  $aliases=@('dispatch-log.jsonl','DISPATCH-LOG.JSONL','./dispatch-log.jsonl','dispatch-log.jsonl.',
    'dispatch-log.jsonl ','dispatch-log.jsonl:reclamation','dispatch-log.jsonl.:reclamation')
  $total=0
  foreach($name in $sources.Keys){
    $errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $name),[ref]$null,[ref]$errors)
    Check ($errors.Count-eq0) "source parses $name"
    $imports=@($ast.EndBlock.Statements|Where-Object{$_.Extent.Text-ceq$import})
    $reads=@($ast.FindAll({param($n)
      ($n -is [Management.Automation.Language.InvokeMemberExpressionAst] -and
       $n.Expression.Extent.Text-ceq'[IO.File]' -and $n.Member.Value-ceq'ReadAllText') -or
      ($n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName()-ceq'Get-Content' -and
       @($n.CommandElements|Where-Object{$_ -is [Management.Automation.Language.CommandParameterAst] -and $_.ParameterName-ceq'Raw'}).Count-eq1)
    },$true))
    Check ($reads.Count-eq1) "complete native register/raw-matrix read inventory $name"
    $total++;$read=$reads[0];$path=$sources[$name]
    $guard="(dispatch-ledger-reader\Get-NonDispatchLedgerPath -Path $path)"
    $probe=Join-Path $root 'probe.ps1'
    $preamble='param([string]$ProbePath)'+"`n"+$import+"`n"+'$path=$Matrix=$ProbePath'+"`n"
    [IO.File]::WriteAllText($probe,$preamble+$read.Extent.Text)
    Check ((& $probe $positive)-ceq$payload) 'actual native read preserves exact text'
    foreach($alias in $aliases){
      $target=Join-Path $root $alias;[IO.File]::WriteAllBytes($target,$bytes)
      $held=[IO.File]::Open($target,'Open','ReadWrite','None')
      try{
        $failure='';try{& $probe $target|Out-Null}catch{$failure=$_.Exception.Message}
        Check ($failure-match'DISPATCH_LEDGER_OWNER_REQUIRED') "owner refusal before actual native read $name/$alias : $failure"
      }finally{$held.Dispose()}
      Check ([Convert]::ToHexString([IO.File]::ReadAllBytes($target))-ceq[Convert]::ToHexString($bytes)) 'alias bytes unchanged'
    }
    Check ($imports.Count-eq1-and$imports[0].Extent.EndOffset-lt$read.Extent.StartOffset) 'literal global non-forcing owner import dominates read'
    if($name-ceq'cleanup-orphan-worktree-dirs.ps1'){
      Check ($read.Arguments.Count-eq2-and$read.Arguments[0].Extent.Text-ceq$guard-and
        $read.Arguments[1].Extent.Text-ceq'[Text.UTF8Encoding]::new($false,$true)') 'original strict UTF8 decoding preserved'
      $invalid=Join-Path $root 'invalid.md';[IO.File]::WriteAllBytes($invalid,[byte[]]@(0xff))
      $failure='';try{& $probe $invalid|Out-Null}catch{$failure=$_.Exception.Message}
      Check ($failure-and$failure-notmatch'DISPATCH_LEDGER_OWNER_REQUIRED') 'invalid ordinary UTF8 still refuses natively'
    }else{
      Check ($read.Extent.Text-ceq"Get-Content -LiteralPath $guard -Raw") 'matrix literal/raw flags and original operand preserved'
    }
    $removed=$read.Extent.Text.Replace($guard,$path)
    Check ($removed-cne$read.Extent.Text) 'exact guard-removal mutation changes read'
    [IO.File]::WriteAllText($probe,$preamble+$removed)
    $target=Join-Path $root 'dispatch-log.jsonl';$held=[IO.File]::Open($target,'Open','ReadWrite','None')
    try{
      $failure='';try{& $probe $target|Out-Null}catch{$failure=$_.Exception.Message}
      Check ($failure-and$failure-notmatch'DISPATCH_LEDGER_OWNER_REQUIRED') 'guard removal reaches actual native sharing failure'
    }finally{$held.Dispose()}
  }
  Check ($total-eq2) 'both original native operands covered'
  Write-Output "PASS ledger-reader-reclamation-matrix-paths checks=$checks native=2 aliases=7 guardRemoval=RED strictUTF8=preserved"
}finally{
  $full=[IO.Path]::GetFullPath($root)
  if((Split-Path -Parent $full).TrimEnd('\','/')-cne([IO.Path]::GetFullPath([IO.Path]::GetTempPath())).TrimEnd('\','/')-or
    (Split-Path -Leaf $full)-cnotlike'ledger-reclamation-matrix-*'){throw 'unsafe reclamation matrix fixture cleanup'}
  Remove-Item -LiteralPath $full -Recurse -Force
}
