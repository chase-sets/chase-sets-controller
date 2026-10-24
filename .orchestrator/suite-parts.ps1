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
    'fixture-equivalence'='FixtureEquivalenceOnly';'precursor'='PrecursorOnly';'legacy'='LegacyOnly'}
}

function Get-HeavySuitePartSelector([string]$Part,$BoundParameters) {
  $map=Get-HeavySuitePartMap
  Assert-SuiteSelection $Part @($map.Keys) $BoundParameters @('NativeDbOnly','DiscriminatorOnly','RulingFourOnly','EligibilityOnly','RoleAdmissionOnly','EligibilityMutant','PrecursorAdmissionDiscriminatorOnly','PrecursorOnly','LegacyOnly','FixtureEquivalenceOnly','TeardownOnly','FixtureMutant')
  if($Part){return $map[$Part]}
}

function Get-DispatchLanePartMap {
  [ordered]@{
    refusal = 'refusal'
    'dispatch-incident-a' = 'dispatch-incident-a'
    'dispatch-incident-b' = 'dispatch-incident-b'
    'dispatch-guard' = 'dispatch-guard'
    'native-branch' = 'native-branch'
  }
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
