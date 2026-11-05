$ErrorActionPreference='Stop'
$checks=0
function Check([bool]$Condition,[string]$Message) {
  $script:checks++
  if(-not $Condition){throw "ASSERTION FAILED: $Message"}
}
$root=Join-Path ([IO.Path]::GetTempPath()) ('ledger-query-paths-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
try {
  $source=Join-Path $PSScriptRoot 'controller-skills/milestone-orchestrator/scripts/query-ledgers.ps1'
  $errors=$null
  $ast=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$null,[ref]$errors)
  Check ($errors.Count -eq 0) 'query source parses'
  $reads=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -ceq 'Get-Content'},$true))
  Check ($reads.Count -eq 2) 'complete native query reader inventory'
  $paths=@('$Path','$resolvedQueryFile')
  $layouts=[ordered]@{
    source=@((Join-Path $root 'source/.orchestrator'),(Join-Path $root 'missing-runtime'))
    installed=@((Join-Path $root 'installed'),(Join-Path $root 'installed-runtime'))
  }
  $payload='synthetic ledger text'
  $positive=Join-Path $root 'ordinary.md'
  [IO.File]::WriteAllText($positive,$payload,[Text.UTF8Encoding]::new($false))
  $bytes=[IO.File]::ReadAllBytes($positive)
  $aliases=@('dispatch-log.jsonl','DISPATCH-LOG.JSONL','./dispatch-log.jsonl','dispatch-log.jsonl.',
    'dispatch-log.jsonl ','dispatch-log.jsonl:query','dispatch-log.jsonl.:query')
  foreach($layout in $layouts.Keys) {
    $runtime=$layouts[$layout][0];$fallback=$layouts[$layout][1]
    $scripts=Join-Path $runtime 'controller-skills/milestone-orchestrator/scripts'
    [void][IO.Directory]::CreateDirectory($scripts)
    $entry=Join-Path $scripts 'query-ledgers.ps1'
    Copy-Item -LiteralPath $source -Destination $entry
    if($layout -ceq 'source') {
      Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'review-head-contract.psm1'),(Join-Path $PSScriptRoot 'dispatch-ledger-reader.psm1') -Destination $runtime
    } else {
      [void][IO.Directory]::CreateDirectory($fallback)
      Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'dispatch-ledger-reader.psm1') -Destination $fallback
    }
    $preamble='param([string]$ProbePath)'+"`n. '"+$entry.Replace("'","''")+"' -Library -RuntimeRoot '"+$fallback.Replace("'","''")+"'`n"+
      '$Path=$resolvedQueryFile=$ProbePath'+"`n"
    for($i=0;$i -lt $reads.Count;$i++) {
      $read=$reads[$i];$path=$paths[$i]
      $guard="(dispatch-ledger-reader\Get-NonDispatchLedgerPath -Path $path)"
      $probe=Join-Path $root 'probe.ps1'
      [IO.File]::WriteAllText($probe,$preamble+$read.Extent.Text)
      Check ((& $probe $positive) -ceq $payload) "actual native raw text/$layout/$i"
      foreach($alias in $aliases) {
        $target=Join-Path $root $alias;[IO.File]::WriteAllBytes($target,$bytes)
        $held=[IO.File]::Open($target,'Open','ReadWrite','None')
        try {
          $failure='';try{& $probe $target|Out-Null}catch{$failure=$_.Exception.Message}
          Check ($failure -match 'DISPATCH_LEDGER_OWNER_REQUIRED') "owner refusal before actual native query read/$layout/$i/$alias : $failure"
        } finally {$held.Dispose()}
        Check ([Convert]::ToHexString([IO.File]::ReadAllBytes($target)) -ceq [Convert]::ToHexString($bytes)) 'canonical alias bytes unchanged'
      }
      Check ($read.Extent.Text -ceq "Get-Content -LiteralPath $guard -Raw") 'literal raw native flags and original operand preserved'
      $removed=$read.Extent.Text.Replace($guard,$path)
      Check ($removed -cne $read.Extent.Text) 'exact guard-removal mutant changes operand'
      [IO.File]::WriteAllText($probe,$preamble+$removed)
      $held=[IO.File]::Open((Join-Path $root 'dispatch-log.jsonl'),'Open','ReadWrite','None')
      try {
        $failure='';try{& $probe (Join-Path $root 'dispatch-log.jsonl')|Out-Null}catch{$failure=$_.Exception.Message}
        Check ($failure -and $failure -notmatch 'DISPATCH_LEDGER_OWNER_REQUIRED') 'guard removal reaches actual sharing refusal'
      } finally {$held.Dispose()}
    }
  }
  $missing=Join-Path $root 'missing-source'
  $scripts=Join-Path $missing 'controller-skills/milestone-orchestrator/scripts'
  [void][IO.Directory]::CreateDirectory($scripts)
  Copy-Item -LiteralPath $source -Destination $scripts
  Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'review-head-contract.psm1') -Destination $missing
  foreach($entry in @((Join-Path $scripts 'query-ledgers.ps1'),(Join-Path $root 'installed/controller-skills/milestone-orchestrator/scripts/query-ledgers.ps1'))) {
    $fallback=if($entry.StartsWith($scripts,[StringComparison]::Ordinal)){Join-Path $root 'installed-runtime'}else{Join-Path $root 'absent-runtime'}
    $failure='';try{& $entry -Library -RuntimeRoot $fallback|Out-Null}catch{$failure=$_.Exception.Message}
    Check ($failure -match 'dispatch-ledger-reader.psm1') 'source owner never borrowed; missing installed owner refuses despite loaded modules'
  }
  Write-Output "PASS ledger-reader-query-paths checks=$checks native=2 layouts=2 aliases=7 guardRemoval=RED missingOwners=REFUSED"
} finally {
  $full=[IO.Path]::GetFullPath($root)
  if((Split-Path -Parent $full).TrimEnd('\','/') -cne ([IO.Path]::GetFullPath([IO.Path]::GetTempPath())).TrimEnd('\','/') -or
    (Split-Path -Leaf $full) -cnotlike 'ledger-query-paths-*'){throw 'unsafe query path fixture cleanup'}
  Remove-Item -LiteralPath $full -Recurse -Force
}
