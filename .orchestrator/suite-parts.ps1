function Assert-SuiteSelection([string]$Part, [string[]]$Names, $BoundParameters, [string[]]$LegacySelectors) {
  if (-not $BoundParameters.ContainsKey('Part')) { return }
  if (-not $Part -or $Part -cnotin $Names) { throw "SUITE_PART: unknown part '$Part'" }
  foreach ($key in $LegacySelectors) {
    if ($BoundParameters.ContainsKey($key)) { throw "SUITE_PART: Part conflicts with $key" }
  }
}

function Test-SuitePart([string]$Part, [string]$Name) {
  return (-not $Part -or $Part -ceq $Name)
}

function Get-HeavySuitePartMap {
  return [ordered]@{'native-db'='NativeDbOnly';'teardown'='TeardownOnly';'role-admission'='RoleAdmissionOnly'
    'fixture-equivalence'='FixtureEquivalenceOnly';'host-heavy-verifier'='HostHeavyVerifierOnly';'precursor'='PrecursorOnly';'legacy'='LegacyOnly'}
}

function Get-HeavySuitePartSelector([string]$Part,$BoundParameters) {
  $map=Get-HeavySuitePartMap
  Assert-SuiteSelection $Part @($map.Keys) $BoundParameters @('NativeDbOnly','DiscriminatorOnly','RulingFourOnly','EligibilityOnly','RoleAdmissionOnly','HostHeavyVerifierOnly','EligibilityMutant','PrecursorAdmissionDiscriminatorOnly','PrecursorOnly','LegacyOnly','FixtureEquivalenceOnly','TeardownOnly','FixtureMutant')
  if($Part){return $map[$Part]}
}

function Get-DispatchLanePartMap {
  [ordered]@{
    'dispatch-foundation' = 'dispatch-foundation'
    'refusal-foundation' = 'refusal-foundation'
    'refusal-harness' = 'refusal-harness'
    'dispatch-incident-a-route' = 'dispatch-incident-a-route'
    'dispatch-incident-a-binding' = 'dispatch-incident-a-binding'
    'dispatch-incident-a-source-native' = 'dispatch-incident-a-source-native'
    'dispatch-incident-b-route-baseline' = 'dispatch-incident-b-route-baseline'
    'dispatch-incident-b-route-matrix' = 'dispatch-incident-b-route-matrix'
    'dispatch-incident-b-binding-structure' = 'dispatch-incident-b-binding-structure'
    'dispatch-incident-b-binding-mutants' = 'dispatch-incident-b-binding-mutants'
    'dispatch-incident-b-source-binding' = 'dispatch-incident-b-source-binding'
    'dispatch-incident-b-source-remote' = 'dispatch-incident-b-source-remote'
    'dispatch-incident-b-native' = 'dispatch-incident-b-native'
    'dispatch-guard-pid' = 'dispatch-guard-pid'
    'dispatch-guard-omission' = 'dispatch-guard-omission'
    'dispatch-guard-reuse' = 'dispatch-guard-reuse'
    'dispatch-guard-arm' = 'dispatch-guard-arm'
    'dispatch-guard-timed' = 'dispatch-guard-timed'
    'dispatch-guard-regression' = 'dispatch-guard-regression'
    'native-branch-scope' = 'native-branch-scope'
    'native-branch-resume' = 'native-branch-resume'
  }
}

function Get-RebaseIntegrationPartMap {
  [ordered]@{
    'rebase-foundation'='rebase-foundation'
    'rebase-historical'='rebase-historical'
    'rebase-ordinary-live'='rebase-ordinary-live'
    'rebase-ordinary-retry'='rebase-ordinary-retry'
    'rebase-successor'='rebase-successor'
    'rebase-publication'='rebase-publication'
    'rebase-amend'='rebase-amend'
  }
}

function Get-LaneWatchdogPartMap {
  [ordered]@{
    'watchdog-foundation'='watchdog-foundation'
    'watchdog-capacity'='watchdog-capacity'
    'watchdog-policy-ac'='watchdog-policy-ac'
    'watchdog-policy-protected'='f1'
    'watchdog-policy-consumed'='r1f2'
    'watchdog-policy-unlinked'='r2f2'
    'watchdog-policy-authentication'='r3'
    'watchdog-policy-scalars'='g2f1'
    'watchdog-policy-joins'='g2f2'
    'watchdog-policy-legacy'='legacy'
    'watchdog-policy-pos'='watchdog-policy-pos'
    'watchdog-policy-mutants-admission'='watchdog-policy-mutants-admission'
    'watchdog-policy-mutants-lineage'='watchdog-policy-mutants-lineage'
    'watchdog-policy-mutants-envelope'='watchdog-policy-mutants-envelope'
    'watchdog-policy-mutants-history'='watchdog-policy-mutants-history'
    'watchdog-policy-mutants-binding'='watchdog-policy-mutants-binding'
    'watchdog-policy-mutants-joins'='watchdog-policy-mutants-joins'
    'watchdog-host-hold-cases'='watchdog-host-hold-cases'
    'watchdog-host-hold-mutants'='watchdog-host-hold-mutants'
    'watchdog-historical'='watchdog-historical'
    'watchdog-ordinary'='watchdog-ordinary'
    'watchdog-successor'='watchdog-successor'
  }
}

function Get-HistoricalSuitePartOwners([ValidateSet('rebase','watchdog')][string]$Suite,[string]$Source) {
  $tokens=$null;$errors=$null
  $ast=[Management.Automation.Language.Parser]::ParseInput($Source.Replace("`r`n","`n"),[ref]$tokens,[ref]$errors)
  if($errors.Count){throw 'SUITE_PART: historical suite source parse failed'}
  $owners=[ordered]@{}
  $families=@{ac='ac';f1='protected';r1f2='consumed';r2f2='unlinked';r3='authentication';g2f1='scalars';g2f2='joins';pos='pos';legacy='legacy'}
  foreach($node in $ast.FindAll({param($n)
    ($n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -clike 'Assert-*' -and $n.GetCommandName() -cne 'Assert-SuiteSelection') -or
    $n -is [Management.Automation.Language.ThrowStatementAst] -or $n -is [Management.Automation.Language.StringConstantExpressionAst] -or
    $n -is [Management.Automation.Language.ExpandableStringExpressionAst]
  },$true)){
    $function='';$parent=$node.Parent
    while($parent){if($parent -is [Management.Automation.Language.FunctionDefinitionAst]){$function=$parent.Name;break};$parent=$parent.Parent}
    $part="$Suite-foundation";$key=$null
    if($Suite -ceq 'watchdog' -and $function -ceq 'Test-PolicyFallback'){
      if($node -is [Management.Automation.Language.StringConstantExpressionAst] -or $node -is [Management.Automation.Language.ExpandableStringExpressionAst]){
        if($node.Value -cmatch '^(ac\d+|f1|r1f2|r2f2|r3|g2f1|g2f2|pos|legacy)-'){
          $family=$Matches[1];if($family -clike 'ac*'){$family='ac'}
          $key='case:'+($node.Value -split '/')[0];$part='watchdog-policy-'+$families[$family]
        }
      }
    }elseif($Suite -ceq 'watchdog' -and $function -ceq 'Test-HostHold' -and
      ($node -is [Management.Automation.Language.StringConstantExpressionAst] -or $node -is [Management.Automation.Language.ExpandableStringExpressionAst]) -and
      $node.Parent -is [Management.Automation.Language.CommandAst] -and $node.Parent.GetCommandName() -ceq 'New-Spec' -and $node.Value -clike 'h1-*'){
      $key='case:host-hold-'+$node.Value;$part='watchdog-host-hold-cases'
    }elseif($Suite -ceq 'watchdog' -and $function -ceq 'Test-PolicyFallbackMutants'){
      continue # Mutant names are read from their tables below, not from guard source strings.
    }elseif($node -is [Management.Automation.Language.CommandAst] -or $node -is [Management.Automation.Language.ThrowStatementAst]){
      $key='proof:'+([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($node.Extent.Text)))).ToLowerInvariant()
      if($Suite -ceq 'watchdog'){
        if($function -cin @('Invoke-HoldWatchdog','Write-HostHold','Get-HoldEffects','Assert-NoHoldEffects','Assert-HostHoldResult','Assert-HoldUnknown','Test-HostHold')){$part='watchdog-host-hold-cases'}
        if($function -ceq 'Test-HostHoldMutants'){$part='watchdog-host-hold-mutants'}
        $parent=$node.Parent
        while($parent){
          if($parent -is [Management.Automation.Language.IfStatementAst] -and $parent.Clauses[0].Item1.Extent.Text -ceq '$CapacityOnly'){$part='watchdog-capacity';break}
          $parent=$parent.Parent
        }
      }
    }
    if($key){
      if($owners.Contains($key)){if($owners[$key] -cne $part){throw "SUITE_PART: conflicting owner $key"}}else{$owners[$key]=$part}
    }
  }
  if($Suite -ceq 'watchdog'){
    foreach($assignment in $ast.FindAll({param($n)$n -is [Management.Automation.Language.AssignmentStatementAst]},$true)){
      if($assignment.Left.Extent.Text -ceq '$hostHoldKills'){
        foreach($arm in @('cases','mutants')){$owners['arm:host-hold-'+$arm]='watchdog-host-hold-'+$arm}
      }
      $parent=$assignment.Parent;$function=''
      while($parent){if($parent -is [Management.Automation.Language.FunctionDefinitionAst]){$function=$parent.Name;break};$parent=$parent.Parent}
      if($function -ceq 'Test-HostHoldMutants' -and $assignment.Left.Extent.Text -ceq '$mutants'){
        foreach($table in $assignment.Right.FindAll({param($n)$n -is [Management.Automation.Language.HashtableAst]},$true)){
          foreach($pair in $table.KeyValuePairs){$owners['mutant:host-hold-'+$pair.Item1.Value]='watchdog-host-hold-mutants'}
        }
      }
    }
    foreach($table in $ast.FindAll({param($n)$n -is [Management.Automation.Language.HashtableAst]},$true)){
      $parent=$table.Parent;$function=''
      while($parent){if($parent -is [Management.Automation.Language.FunctionDefinitionAst]){$function=$parent.Name;break};$parent=$parent.Parent}
      if($function -ceq 'Test-HostHold'){
        foreach($pair in $table.KeyValuePairs){if($pair.Item1.Value -ceq 'name'){$owners['case:host-hold-bad-'+[string]$pair.Item2.SafeGetValue()]='watchdog-host-hold-cases'}}
      }
      if($function -cne 'Test-PolicyFallbackMutants'){continue}
      $name='';$case=''
      foreach($pair in $table.KeyValuePairs){
        if($pair.Item1.Value -ceq 'name'){$name=[string]$pair.Item2.SafeGetValue()}
        if($pair.Item1.Value -ceq 'case'){$case=[string]$pair.Item2.SafeGetValue()}
      }
      if($name){
        $group=switch -Regex ($case){
          '^(ac|f1|pos)'{'admission';break}
          '^(r1f2|r2f2)'{'lineage';break}
          '^r3-envelope'{'envelope';break}
          '^r3-history'{'history';break}
          '^r3-(source|request|ack|scan)'{'binding';break}
          '^g2f'{'joins';break}
          default{throw "SUITE_PART: unowned policy mutant $name case=$case"}
        }
        $owners['mutant:'+$name]="watchdog-policy-mutants-$group"
      }
    }
  }
  if($Suite -ceq 'rebase'){
    foreach($name in @('historical','ordinary-live','ordinary-retry','successor','publication','amend')){$owners["carrier:$name"]="rebase-$name"}
  }else{
    foreach($name in @('capacity','historical','ordinary','successor')){$owners["carrier:$name"]="watchdog-$name"}
  }
  return $owners
}

function Get-SuiteRoutingNames([string]$Source) {
  $tokens=$null; $errors=$null
  $ast=[Management.Automation.Language.Parser]::ParseInput($Source,[ref]$tokens,[ref]$errors)
  if ($errors.Count) { throw 'SUITE_PART: source parse failed' }
  $result=[ordered]@{cases=@();mutants=@();capacityMutants=@()}
  foreach ($assignment in $ast.FindAll({param($n) $n -is [Management.Automation.Language.AssignmentStatementAst]},$true)) {
    $name=$assignment.Left.Extent.Text.TrimStart('$')
    if ($name -cnotin @('cases','mutants','capacityMutants')) { continue }
    if ($name -ceq 'cases') {
      $result.cases=@($assignment.Right.FindAll({param($n) $n -is [Management.Automation.Language.StringConstantExpressionAst]},$true) | ForEach-Object Value)
    } else {
      foreach ($table in $assignment.Right.FindAll({param($n) $n -is [Management.Automation.Language.HashtableAst]},$true)) {
        foreach ($pair in $table.KeyValuePairs) {
          if ($pair.Item1.Extent.Text -ceq 'name') { $result[$name]+= [string]$pair.Item2.SafeGetValue() }
        }
      }
    }
  }
  return $result
}

function Get-SuiteRoutingParts([string]$Source) {
  $names=Get-SuiteRoutingNames $Source
  return @(@($names.cases | ForEach-Object { "case-$_" }) +
    @($names.mutants | ForEach-Object { "routing-mutant-$_" }) +
    @($names.capacityMutants | ForEach-Object { "capacity-mutant-$_" }))
}

function Get-SuiteExpectedParts([string]$Path) {
  $source=[IO.File]::ReadAllText($Path)
  if((Split-Path -Leaf $Path)-ceq'dispatch-routing-data.test.ps1'){return Get-SuiteRoutingParts $source}
  if((Split-Path -Leaf $Path)-ceq'invoke-heavy-verifier.test.ps1'){return @((Get-HeavySuitePartMap).Keys)}
  if((Split-Path -Leaf $Path)-ceq'dispatch-lane.test.ps1'){return @((Get-DispatchLanePartMap).Keys)}
  if((Split-Path -Leaf $Path)-ceq'rebase-integration.test.ps1'){return @((Get-RebaseIntegrationPartMap).Keys)}
  if((Split-Path -Leaf $Path)-ceq'lane-stall-watchdog.test.ps1'){return @((Get-LaneWatchdogPartMap).Keys)}
  $tokens=$null;$errors=$null
  $ast=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors)
  if($errors.Count){throw 'SUITE_PART: source parse failed'}
  if((Split-Path -Leaf $Path)-ceq'board-hourly-scale.test.ps1'){
    return @($ast.ParamBlock.Parameters[0].Attributes | Where-Object TypeName -Match 'ValidateSet' |
      ForEach-Object {$_.PositionalArguments | ForEach-Object Value} | Where-Object {$_-cne'all'})
  }
  $selectors=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName()-ceq'Assert-SuiteSelection'},$false))
  if($selectors.Count-ne1){throw 'SUITE_PART: missing/duplicate selection contract'}
  return @($selectors[0].CommandElements[2].SafeGetValue())
}
