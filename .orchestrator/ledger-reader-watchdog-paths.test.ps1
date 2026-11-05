$ErrorActionPreference='Stop'
$script:checks=0
function Check([bool]$Condition,[string]$Message) {
  $script:checks++
  if(-not $Condition){throw "ASSERTION FAILED: $Message"}
}
$root=Join-Path ([IO.Path]::GetTempPath()) ('ledger-watchdog-paths-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
try {
  Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'dispatch-ledger-reader.psm1') -Destination $root
  $import="Import-Module (Join-Path `$PSScriptRoot 'dispatch-ledger-reader.psm1') -Force -DisableNameChecking"
  $sources=[ordered]@{
    'lane-stall-watchdog.ps1'=@('$Path','$resolved','$path','$Path','$AckPath','$file.FullName','$file.FullName','$specPath','$ObservationFixture','$ackPath')
    'lane-stall-watchdog-batch.ps1'=@('(Native-Path $LanesPath)')
  }
  $payload='{"schemaVersion":4,"synthetic":true}'
  $positive=Join-Path $root 'receipt.json'
  [IO.File]::WriteAllText($positive,$payload,[Text.UTF8Encoding]::new($false))
  $bytes=[IO.File]::ReadAllBytes($positive)
  $aliases=@('dispatch-log.jsonl','DISPATCH-LOG.JSONL','./dispatch-log.jsonl',
    'dispatch-log.jsonl.','dispatch-log.jsonl ','dispatch-log.jsonl:watchdog','dispatch-log.jsonl.:watchdog')
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
        $node.Expression.Extent.Text -ceq '[IO.File]' -and $node.Member.Value -cin @('ReadAllText','ReadAllBytes'))
    },$true))
    Check ($reads.Count -eq $sources[$name].Count) "complete native expression inventory $name"
    $definitions=''
    if($name -ceq 'lane-stall-watchdog-batch.ps1') {
      $native=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Native-Path'},$true))
      Check ($native.Count -eq 1) 'actual batch normalization body'
      $definitions=$native[0].Extent.Text
    }
    $bindings='$Path=$resolved=$AckPath=$specPath=$ObservationFixture=$LanesPath=$ProbePath;$file=[pscustomobject]@{FullName=$ProbePath}'
    $preamble='param([string]$ProbePath)'+"`n"+$import+"`n"+$definitions+"`n"+$bindings+"`n"
    for($index=0;$index -lt $reads.Count;$index++) {
      $total++
      $read=$reads[$index]
      $path=$sources[$name][$index]
      $guard="(dispatch-ledger-reader\Get-NonDispatchLedgerPath -Path $path)"
      [IO.File]::WriteAllText($probe,$preamble+$read.Extent.Text)
      $result=& $probe $positive
      if($read -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $read.Member.Value -ceq 'ReadAllBytes') {
        Check ([Convert]::ToHexString([byte[]]$result) -ceq [Convert]::ToHexString($bytes)) "exact native bytes $name/$index"
        $wsl=$positive -replace '^([A-Za-z]):[\\/]', '/mnt/$1/' -replace '\\','/'
        Check ([Convert]::ToHexString([byte[]](& $probe $wsl)) -ceq [Convert]::ToHexString($bytes)) 'actual WSL path normalization preserved'
      } else {Check ($result -ceq $payload) "exact native text $name/$index"}
      foreach($alias in $aliases) {
        $target=Join-Path $root $alias
        [IO.File]::WriteAllBytes($target,$bytes)
        $held=[IO.File]::Open($target,'Open','ReadWrite','None')
        try {
          $failure=''
          try {& $probe $target | Out-Null}catch{$failure=$_.Exception.Message}
          Check ($failure -match 'DISPATCH_LEDGER_OWNER_REQUIRED') "owner refusal before native I/O $name/$index/$alias : $failure"
        } finally {$held.Dispose()}
        Check ([Convert]::ToHexString([IO.File]::ReadAllBytes($target)) -ceq [Convert]::ToHexString($bytes)) 'alias bytes untouched'
      }
      Check ($imports.Count -eq 1 -and $imports[0].Extent.EndOffset -lt $read.Extent.StartOffset) "literal unconditional owner import precedes $name/$index"
      $expected=if($read -is [Management.Automation.Language.CommandAst]) {"Get-Content -LiteralPath $guard -Raw"} else {"[IO.File]::$($read.Member.Value)($guard)"}
      Check ($read.Extent.Text -ceq $expected) "only original path operand changed $name/$index"
      $mutant=$read.Extent.Text.Replace($guard,$path)
      Check ($mutant -cne $read.Extent.Text) 'exact guard removal changes expression'
      [IO.File]::WriteAllText($probe,$preamble+$mutant)
      $canonical=Join-Path $root 'dispatch-log.jsonl'
      $held=[IO.File]::Open($canonical,'Open','ReadWrite','None')
      try {
        $failure=''
        try {& $probe $canonical | Out-Null}catch{$failure=$_.Exception.Message}
        Check ($failure -and $failure -notmatch 'DISPATCH_LEDGER_OWNER_REQUIRED') "guard removal exposes actual native failure $name/$index"
      } finally {$held.Dispose()}
    }
    if($name -ceq 'lane-stall-watchdog.ps1') {
      $history=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ceq 'Read-ExactHeadReviewHistory'},$true))
      Check ($history.Count -eq 4) 'all four canonical history owner calls retained'
      foreach($call in $history){Check ($call.Extent.Text -ceq 'Read-ExactHeadReviewHistory -Path $HistoryPath') 'history not relabeled non-dispatch'}
      $tail=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Get-Tail'},$true))
      Check ($tail.Count -eq 1) 'complete actual tail function'
      [IO.File]::WriteAllText($probe,$import+"`n"+$tail[0].Extent.Text)
      . $probe
      Check ((Get-Tail $positive) -ceq $payload) 'complete tail preserves payload'
      $long=Join-Path $root 'long.txt';[IO.File]::WriteAllText($long,('x'*20000)+'END')
      Check ((Get-Tail $long) -ceq (('x'*16381)+'END')) 'complete tail retains exact suffix bound'
      Check ((Get-Tail (Join-Path $root 'absent.txt')) -ceq '') 'complete tail retains absent-file behavior'
      $held=[IO.File]::Open((Join-Path $root 'dispatch-log.jsonl'),'Open','ReadWrite','None')
      try {
        $failure='';try {Get-Tail (Join-Path $root 'dispatch-log.jsonl') | Out-Null}catch{$failure=$_.Exception.Message}
        Check ($failure -match 'DISPATCH_LEDGER_OWNER_REQUIRED') 'complete tail refuses before native read'
      } finally {$held.Dispose()}
    }
  }
  Write-Output "PASS ledger-reader-watchdog-paths checks=$script:checks native=$total aliases=7 guardRemoval=RED"
} finally {
  $full=[IO.Path]::GetFullPath($root)
  if((Split-Path -Parent $full).TrimEnd('\','/') -cne ([IO.Path]::GetFullPath([IO.Path]::GetTempPath())).TrimEnd('\','/') -or
    (Split-Path -Leaf $full) -cnotlike 'ledger-watchdog-paths-*'){throw 'unsafe watchdog fixture cleanup'}
  Remove-Item -LiteralPath $full -Recurse -Force
}
