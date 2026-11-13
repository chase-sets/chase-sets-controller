$ErrorActionPreference='Stop'
$script:checks=0
function Check([bool]$Condition,[string]$Message) {
  $script:checks++
  if(-not $Condition){throw "ASSERTION FAILED: $Message"}
}
$root=Join-Path ([IO.Path]::GetTempPath()) ('ledger-dispatch-paths-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
try {
  Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'dispatch-ledger-reader.psm1') -Destination $root
  $import="Import-Module (Join-Path `$PSScriptRoot 'dispatch-ledger-reader.psm1') -DisableNameChecking"
  $sources=[ordered]@{
    'dispatch-lane.ps1'=@('$Path','$source.location','$reviewContractPath','$planningContractPath','$promptResolved','$longProductGateResultPath')
    'landed-integration-dispatch.ps1'=@('$GraphFixturePath','$path','$owed','$owed','$owed','$owed')
  }
  $payload='{"schemaVersion":"lane-priority/v1","priorityClass":"Idle"}'
  $positive=Join-Path $root 'priority.json'
  [IO.File]::WriteAllText($positive,$payload,[Text.UTF8Encoding]::new($false))
  $bytes=[IO.File]::ReadAllBytes($positive)
  $aliases=@('dispatch-log.jsonl','DISPATCH-LOG.JSONL','./dispatch-log.jsonl',
    'dispatch-log.jsonl.','dispatch-log.jsonl ','dispatch-log.jsonl:dispatch','dispatch-log.jsonl.:dispatch')
  $probe=Join-Path $root 'probe.ps1'
  $bindings='$Path=$reviewContractPath=$planningContractPath=$promptResolved=$longProductGateResultPath=$GraphFixturePath=$path=$owed=$ProbePath;$source=[pscustomobject]@{location=$ProbePath}'
  $preamble='param([string]$ProbePath)'+"`n"+$import+"`n"+$bindings+"`n"
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
    Check ($reads.Count -eq $sources[$name].Count) "complete native read inventory $name"
    for($index=0;$index -lt $reads.Count;$index++) {
      $total++
      $read=$reads[$index];$path=$sources[$name][$index]
      $guard="(dispatch-ledger-reader\Get-NonDispatchLedgerPath -Path $path)"
      [IO.File]::WriteAllText($probe,$preamble+$read.Extent.Text)
      $result=& $probe $positive
      if($read -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $read.Member.Value -ceq 'ReadAllBytes') {
        Check ([Convert]::ToHexString([byte[]]$result) -ceq [Convert]::ToHexString($bytes)) "exact native bytes $name/$index"
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
      Check ($imports.Count -eq 1 -and $imports[0].Extent.EndOffset -lt $read.Extent.StartOffset) "literal non-forcing owner import precedes $name/$index"
      $expected=if($read -is [Management.Automation.Language.CommandAst]) {"Get-Content -LiteralPath $guard -Raw"} else {"[IO.File]::$($read.Member.Value)($guard)"}
      Check ($read.Extent.Text -ceq $expected) "only original path operand changed $name/$index"
      $mutant=$read.Extent.Text.Replace($guard,$path)
      Check ($mutant -cne $read.Extent.Text) 'exact guard removal changes expression'
      [IO.File]::WriteAllText($probe,$preamble+$mutant)
      $canonical=Join-Path $root 'dispatch-log.jsonl'
      $held=[IO.File]::Open($canonical,'Open','ReadWrite','None')
      try {
        $failure=''
        try {& $probe $canonical|Out-Null}catch{$failure=$_.Exception.Message}
        Check ($failure -and $failure -notmatch 'DISPATCH_LEDGER_OWNER_REQUIRED') "guard removal exposes native sharing failure $name/$index"
      } finally {$held.Dispose()}
    }
    $writes=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and
      $node.Expression.Extent.Text -ceq '[IO.File]' -and $node.Member.Value -ceq 'Open'},$true))
    $writePath=if($name -ceq 'dispatch-lane.ps1'){'$startAcknowledgementFull'}else{'$owed'}
    Check ($writes.Count -eq 1 -and $writes[0].Extent.Text -ceq "[IO.File]::Open($writePath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)") "create-only writer overload unchanged $name"
    $history=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ceq 'Read-ExactHeadReviewHistory'},$true))
    if($name -ceq 'dispatch-lane.ps1') {
      Check ($history.Count -eq 0) 'launcher delegates canonical history instead of retaining a second adapter'
      $capacity=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ceq 'Resolve-CapacityRouting'},$true))
      Check ($capacity.Count -eq 1) 'one actual launcher capacity resolver'
      $routingImport=". (Join-Path `$PSScriptRoot 'routing-data.ps1') -Library -StateRoot `$RoutingStateRoot -LkgPath `$RoutingLkgPath"
      $routingImports=@($ast.EndBlock.Statements|Where-Object {$_.Extent.Text -ceq $routingImport})
      Check ($routingImports.Count -eq 1 -and $routingImports[0].Extent.EndOffset -lt $capacity[0].Extent.StartOffset) 'actual routing library loaded before history delegation'
      $historyParameters=@($capacity[0].CommandElements|Where-Object {$_ -is [Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -ceq 'HistoryPath'})
      Check ($historyParameters.Count -eq 1) 'one canonical history path argument'
      $pathIndex=$capacity[0].CommandElements.IndexOf($historyParameters[0])+1
      Check ($pathIndex -lt $capacity[0].CommandElements.Count -and $capacity[0].CommandElements[$pathIndex].Extent.Text -ceq "(Join-Path `$runtimeRoot 'dispatch-log.jsonl')") 'launcher passes canonical runtime ledger to capacity owner'
      # Follow the real delegation; an arbitrary resolver call is not proof
      # that canonical history still reaches the sole reader.
      $routingErrors=$null
      $routingAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'routing-data.ps1'),[ref]$null,[ref]$routingErrors)
      Check ($routingErrors.Count -eq 0) 'production routing library parses'
      $resolver=@($routingAst.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Resolve-CapacityRouting'},$true))
      $authorHistory=@($routingAst.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Get-CapacityAuthorHistory'},$true))
      Check ($resolver.Count -eq 1 -and $authorHistory.Count -eq 1) 'complete actual capacity history bodies'
      $forward=@($resolver[0].Body.FindAll({param($node)$node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ceq 'Get-CapacityAuthorHistory'},$true))
      Check ($forward.Count -eq 1 -and $forward[0].Extent.Text -ceq 'Get-CapacityAuthorHistory -Path $HistoryPath @historyArguments -Registry $data.registry') 'resolver preserves canonical history argument and attribution inputs'
      $snapshots=@($authorHistory[0].Body.FindAll({param($node)$node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ceq 'dispatch-ledger-reader\Read-DispatchLedgerSnapshot'},$true))
      Check ($snapshots.Count -eq 1 -and $snapshots[0].Extent.Text -ceq 'dispatch-ledger-reader\Read-DispatchLedgerSnapshot -Path $Path -RequireTerminated') 'capacity history retains sole-reader ownership and terminated-ledger requirement'
      $ownerImport=$import.Replace(' -DisableNameChecking',' -Global -DisableNameChecking')
      $ownerImports=@($routingAst.EndBlock.Statements|Where-Object {$_.Extent.Text -ceq $ownerImport})
      Check ($ownerImports.Count -eq 1 -and $ownerImports[0].Extent.EndOffset -lt $authorHistory[0].Extent.StartOffset) 'literal routing owner import precedes canonical reader'
      $priority=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Get-LanePriority'},$true))
      Check ($priority.Count -eq 1) 'complete actual priority body'
      [IO.File]::WriteAllText($probe,$import+"`n"+$priority[0].Extent.Text)
      . $probe
      $value=Get-LanePriority $positive ''
      Check ($value.priorityClass -ceq 'Idle' -and $value.prioritySource -ceq 'file') 'complete priority body reads allowed configuration'
      $missing=Get-LanePriority (Join-Path $root 'absent.json') ''
      Check ($missing.priorityClass -ceq 'BelowNormal' -and $missing.prioritySource -ceq 'default') 'priority missing-file default retained'
      foreach($alias in $aliases) {
        $target=Join-Path $root $alias
        $value=Get-LanePriority $target ''
        Check ($value.priorityClass -ceq 'Normal' -and $value.prioritySource -ceq 'fallback:unreadable-or-invalid-json') 'complete priority body refuses canonical alias despite valid config bytes'
        $override=Get-LanePriority $target 'Idle'
        Check ($override.priorityClass -ceq 'Idle' -and $override.prioritySource -ceq 'parameter') 'explicit priority does not read configuration'
      }
    } else {
      Check ($history.Count -eq 3) 'three landed dispatcher history owner calls retained'
      foreach($call in $history){Check ($call.Extent.Text -ceq 'Read-ExactHeadReviewHistory -Path $HistoryPath') 'history not relabeled non-dispatch'}
    }
  }
  Write-Output "PASS ledger-reader-dispatch-paths checks=$script:checks native=$total aliases=7 guardRemoval=RED"
} finally {
  $full=[IO.Path]::GetFullPath($root)
  if((Split-Path -Parent $full).TrimEnd('\','/') -cne ([IO.Path]::GetFullPath([IO.Path]::GetTempPath())).TrimEnd('\','/') -or
    (Split-Path -Leaf $full) -cnotlike 'ledger-dispatch-paths-*'){throw 'unsafe dispatch fixture cleanup'}
  Remove-Item -LiteralPath $full -Recurse -Force
}
