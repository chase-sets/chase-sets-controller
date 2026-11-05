# Static, tracked-source census. Never loads or executes the inspected scripts.
function Get-LedgerReaderCensus {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$Root,[hashtable]$SourceOverride=@{})
  $paths=@(& git -C $Root ls-files -- '*.ps1' '*.psm1' '*.cs')
  if ($LASTEXITCODE -ne 0 -or -not $paths.Count) { throw 'LEDGER_CENSUS_INVENTORY_MISSING' }
  Write-Verbose "Ledger census: parsing $($paths.Count) tracked sources"
  $units=[Collections.Generic.List[object]]::new();$functions=@{};$facts=@{};$types=@{}
  $variableKeys=@{};$factParts=@{};$scriptParts=@{};$assignmentShapes=@{}
  $pathAssignments=@{};$pathParameters=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  $stringParameters=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  $scriptAliases=@{};$trackedScripts=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  $dataFunctions=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  foreach ($name in @('read-dispatchledgersnapshot','read-dispatchledgerlines','read-dispatchledgerbytes','read-dispatchcounthistory','read-exactheadreviewhistory')) { [void]$dataFunctions.Add($name) }
  $rows=[Collections.Generic.List[object]]::new()
  function TokenShape($Node) {
    $tokens=$null;$errors=$null
    $null=[Management.Automation.Language.Parser]::ParseInput($Node.Extent.Text,[ref]$tokens,[ref]$errors)
    if ($errors.Count) { return '' }
    return (@($tokens | Where-Object { $_.Kind -notin @('NewLine','Comment','EndOfInput') } | ForEach-Object { "$($_.Kind):$($_.Text)" }) -join "`n")
  }
  function ReaderPath($Node) {
    if ($Node -isnot [Management.Automation.Language.CommandAst]) { return $Node }
    $elements=$Node.CommandElements
    if (@($elements | Where-Object { $_ -is [Management.Automation.Language.VariableExpressionAst] -and $_.Splatted }).Count) { return $null }
    $paths=@()
    for ($i=1;$i -lt $elements.Count;$i++) {
      $element=$elements[$i]
      if ($element -is [Management.Automation.Language.CommandParameterAst] -and $element.ParameterName -in @('Path','LiteralPath')) {
        if ($element.Argument) { $paths+=,$element.Argument }
        elseif ($i+1 -lt $elements.Count -and $elements[$i+1] -isnot [Management.Automation.Language.CommandParameterAst]) { $i++;$paths+=,$elements[$i] }
        else { return $null }
      }
    }
    if ($paths.Count -eq 1) { return $paths[0] }
    if ($paths.Count -eq 0 -and $elements.Count -gt 1 -and $elements[1] -isnot [Management.Automation.Language.CommandParameterAst]) { return $elements[1] }
    return $null
  }
  function HasPathGuard($Node,$Path,$Unit) {
    if (-not $nonDispatchGuardValid -or -not $guardImports.ContainsKey($Unit.path) -or $guardImports[$Unit.path] -ge $Node.Extent.StartOffset -or $Path -isnot [Management.Automation.Language.VariableExpressionAst]) { return $false }
    if (-not $stringParameters.Contains((Key $Path $Unit))) { return $false }
    $statement=$Node
    while ($statement.Parent -and $statement.Parent -isnot [Management.Automation.Language.StatementBlockAst] -and $statement.Parent -isnot [Management.Automation.Language.NamedBlockAst]) { $statement=$statement.Parent }
    $block=$statement.Parent
    if (-not $block) { return $false }
    $index=$block.Statements.IndexOf($statement)
    if ($index -lt 1) { return $false }
    $previous=$block.Statements[$index-1]
    if ($previous -isnot [Management.Automation.Language.PipelineAst] -or $previous.PipelineElements.Count -ne 1) { return $false }
    $call=$previous.PipelineElements[0]
    if ($call -isnot [Management.Automation.Language.CommandAst] -or $call.GetCommandName() -cne 'dispatch-ledger-reader\Assert-NonDispatchLedgerPath' -or $call.CommandElements.Count -ne 3) { return $false }
    $parameter=$call.CommandElements[1];$value=$call.CommandElements[2]
    return $parameter -is [Management.Automation.Language.CommandParameterAst] -and $parameter.ParameterName -ceq 'Path' -and -not $parameter.Argument -and
      $value -is [Management.Automation.Language.VariableExpressionAst] -and (Key $value $Unit) -ceq (Key $Path $Unit)
  }
  function Scope($Node,$Unit) {
    $parent=$Node.Parent
    while ($null -ne $parent) {
      if ($parent -is [Management.Automation.Language.FunctionDefinitionAst]) { return "$($Unit.path)::$($parent.Extent.StartOffset)" }
      $parent=$parent.Parent
    }
    return "$($Unit.path)::script"
  }
  function Key($Node,$Unit) {
    if ($variableKeys.ContainsKey($Node)) { return $variableKeys[$Node] }
    $name=$Node.VariablePath.UserPath.ToLowerInvariant()
    $key=if ($name -match '^(script|global):(.+)$') { "$($Unit.path)::script::$($Matches[2])" }
      else { (Scope $Node $Unit)+'::'+($name -replace '^(local|private):','') }
    $variableKeys[$Node]=$key
    return $key
  }
  function Fact($Node,$Unit) {
    if ($null -eq $Node) { return 0 }
    $mask=0
    if (-not $factParts.ContainsKey($Node)) {
      $parts=@($Node.FindAll({param($n) $n -is [Management.Automation.Language.StringConstantExpressionAst] -or
          $n -is [Management.Automation.Language.ExpandableStringExpressionAst] -or $n -is [Management.Automation.Language.VariableExpressionAst]},$true))
      $factParts[$Node]=@($parts | Where-Object {
        $ancestor=$_;$nested=$false
        while ($ancestor -and $ancestor -ne $Node) {
          if ($ancestor -is [Management.Automation.Language.ScriptBlockExpressionAst] -or $ancestor -is [Management.Automation.Language.FunctionDefinitionAst]) { $nested=$true;break }
          $ancestor=$ancestor.Parent
        }
        -not $nested
      })
    }
    foreach ($part in $factParts[$Node]) {
      if ($part -is [Management.Automation.Language.VariableExpressionAst]) {
        $key=Key $part $Unit
        if ($facts.ContainsKey($key)) { $mask=$mask -bor $facts[$key] }
        # Script-scope defaults are visible to functions; same-named local
        # parameters still gain facts only from actual call binding below.
        $scriptKey="$($Unit.path)::script::$($part.VariablePath.UserPath.ToLowerInvariant())"
        if ($facts.ContainsKey($scriptKey)) { $mask=$mask -bor $facts[$scriptKey] }
      } else {
        if ($part.Value -match '(?i)dispatch-log(?:\\?\.)jsonl') { $mask=$mask -bor 1 }
        if ($part.Value -match '(?i)cost-ledger(?:\\?\.)jsonl') { $mask=$mask -bor 2 }
      }
    }
    return $mask
  }
  function AddFact([string]$Key,[int]$Mask) {
    if (-not $facts.ContainsKey($Key)) { $facts[$Key]=0 }
    $before=$facts[$Key];$facts[$Key]=$before -bor $Mask
    return $before -ne $facts[$Key]
  }
  function NonLedgerPath($Node,$Unit,[string[]]$Visiting=@()) {
    if (-not $Node -or $Visiting.Count -ge 12) { return $false }
    if ($Node -is [Management.Automation.Language.StringConstantExpressionAst]) {
      $leaf=($Node.Value -split '[/\\]')[-1]
      return $leaf -notin @('','.','..') -and $Node.Value -notmatch '(?i)dispatch-log(?:\\?\.)jsonl'
    }
    if ($Node -is [Management.Automation.Language.VariableExpressionAst]) {
      $key=Key $Node $Unit
      if ($key -in $Visiting -or $pathParameters.Contains($key) -or -not $pathAssignments.ContainsKey($key)) { return $false }
      $block=$Node.Parent
      while ($block -and $block -isnot [Management.Automation.Language.StatementBlockAst] -and $block -isnot [Management.Automation.Language.NamedBlockAst]) { $block=$block.Parent }
      if (-not $block) { return $false }
      $statement=$Node
      while ($statement.Parent -and $statement.Parent -ne $block) { $statement=$statement.Parent }
      $index=$block.Statements.IndexOf($statement)
      if ($index -lt 1) { return $false }
      $dominating=$false
      foreach ($assignment in $pathAssignments[$key]) {
        # An intervening command can mutate a scoped or by-reference variable.
        # Only the immediately preceding assignment is a local exclusion proof.
        if ($assignment -eq $block.Statements[$index-1]) { $dominating=$true }
        if (-not (NonLedgerPath $assignment.Right $Unit ($Visiting+$key))) { return $false }
      }
      return $dominating
    }
    if ($Node -is [Management.Automation.Language.CommandExpressionAst]) { return NonLedgerPath $Node.Expression $Unit $Visiting }
    if ($Node -is [Management.Automation.Language.ParenExpressionAst]) { return NonLedgerPath $Node.Pipeline $Unit $Visiting }
    if ($Node -is [Management.Automation.Language.PipelineAst] -and $Node.PipelineElements.Count -eq 1) { return NonLedgerPath $Node.PipelineElements[0] $Unit $Visiting }
    if ($Node -is [Management.Automation.Language.StatementBlockAst] -and $Node.Statements.Count -eq 1) { return NonLedgerPath $Node.Statements[0] $Unit $Visiting }
    if ($Node -is [Management.Automation.Language.CommandAst] -and $Node.GetCommandName() -ieq 'Join-Path' -and
        $Node.CommandElements.Count -eq 3 -and -not @($Node.CommandElements | Where-Object { $_ -is [Management.Automation.Language.CommandParameterAst] }).Count) {
      # Only a fixed final leaf proves exclusion. Flags, additional segments,
      # function returns and opaque inputs are deliberately not inferred safe.
      $leaf=$Node.CommandElements[2]
      return $leaf -is [Management.Automation.Language.StringConstantExpressionAst] -and (NonLedgerPath $leaf $Unit $Visiting)
    }
    return $false
  }
  function CommandName($Node,$Unit) {
    $name=$Node.GetCommandName()
    if ($null -eq $name) {
      $head=$Node.CommandElements[0]
      foreach ($literal in $head.FindAll({param($n) $n -is [Management.Automation.Language.StringConstantExpressionAst]},$true)) {
        $leaf=($literal.Value -split '[/\\]')[-1]
        if ($trackedScripts.Contains($leaf)) { return $leaf.ToLowerInvariant() }
      }
      if ($head -is [Management.Automation.Language.VariableExpressionAst]) {
        $key=Key $head $Unit
        if ($scriptAliases.ContainsKey($key) -and $scriptAliases[$key].Count -eq 1) { return @($scriptAliases[$key])[0].ToLowerInvariant() }
      }
      return ''
    }
    return ($name -split '\\')[-1].ToLowerInvariant()
  }
  function ScriptNames($Node,$Unit) {
    if (-not $Node) { return }
    if (-not $scriptParts.ContainsKey($Node)) {
      $scriptParts[$Node]=@($Node.FindAll({param($n) $n -is [Management.Automation.Language.StringConstantExpressionAst] -or $n -is [Management.Automation.Language.VariableExpressionAst]},$true))
    }
    foreach ($part in $scriptParts[$Node]) {
      if ($part -is [Management.Automation.Language.VariableExpressionAst]) {
        $key=Key $part $Unit
        if ($scriptAliases.ContainsKey($key)) { foreach ($name in $scriptAliases[$key]) { $name } }
      } else {
        $leaf=($part.Value -split '[/\\]')[-1]
        if ($trackedScripts.Contains($leaf)) { $leaf }
      }
    }
  }
  function AddScriptAlias([string]$Key,$Names) {
    if (-not $scriptAliases.ContainsKey($Key)) { $scriptAliases[$Key]=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase) }
    $updated=$false
    foreach ($name in $Names) { if ($scriptAliases[$Key].Add($name)) { $updated=$true } }
    return $updated
  }
  function Arguments($Call,$Parameters) {
    $bound=@{};$position=0;$elements=$Call.CommandElements
    for ($i=1;$i -lt $elements.Count;$i++) {
      $element=$elements[$i]
      if ($element -is [Management.Automation.Language.CommandParameterAst]) {
        $name=$element.ParameterName.ToLowerInvariant()
        if ($element.Argument) { $bound[$name]=$element.Argument }
        elseif ($i+1 -lt $elements.Count -and $elements[$i+1] -isnot [Management.Automation.Language.CommandParameterAst]) { $i++;$bound[$name]=$elements[$i] }
      } elseif ($position -lt $Parameters.Count) { $bound[$Parameters[$position].Name.VariablePath.UserPath.ToLowerInvariant()]=$element;$position++ }
    }
    return $bound
  }
  foreach ($path in $paths) {
    if ($path.EndsWith('.ps1')) { [void]$trackedScripts.Add(($path -split '/')[-1]) }
  }
  foreach ($path in $paths) {
    $full=Join-Path $Root $path
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw "LEDGER_CENSUS_PATH_MISSING:$path" }
    $source=if ($SourceOverride.ContainsKey($path)) { $SourceOverride[$path] } else { [IO.File]::ReadAllText($full) }
    $test=$path -match '(?i)(^|/)(fixtures|diagnostics)/|(?:\.test|\.check|\.test-support|-test-support|-fixture-harness|-test-fixture)\.ps1$|/issue-\d+-(?:discriminator|live-readonly-proof)\.ps1$'
    if ($path.EndsWith('.cs')) { $units.Add([pscustomobject]@{path=$path;source=$source;test=$test;ast=$null});continue }
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors)
    if ($errors.Count) { throw "LEDGER_CENSUS_PARSE_FAILED:$path" }
    $unit=[pscustomobject]@{path=$path;source=$source;test=$test;ast=$ast
      assignments=@(if (-not $test) { $ast.FindAll({param($n) $n -is [Management.Automation.Language.AssignmentStatementAst]},$true) })
      parameters=@(if (-not $test) { $ast.FindAll({param($n) $n -is [Management.Automation.Language.ParameterAst]},$true) })
      loops=@(if (-not $test) { $ast.FindAll({param($n) $n -is [Management.Automation.Language.ForEachStatementAst]},$true) })
      calls=@(if (-not $test) { $ast.FindAll({param($n) $n -is [Management.Automation.Language.CommandAst]},$true) })};$units.Add($unit)
    if ($test) { continue }
    foreach ($parameter in $unit.parameters) {
      $key=Key $parameter.Name $unit
      [void]$pathParameters.Add($key)
      if (@($parameter.Attributes | Where-Object { $_ -is [Management.Automation.Language.TypeConstraintAst] -and $_.TypeName.FullName -in @('string','System.String') }).Count) { [void]$stringParameters.Add($key) }
    }
    foreach ($assignment in $unit.assignments) {
      if ($assignment.Left -isnot [Management.Automation.Language.VariableExpressionAst]) { continue }
      $key=Key $assignment.Left $unit
      if (-not $pathAssignments.ContainsKey($key)) { $pathAssignments[$key]=@() }
      $pathAssignments[$key]+=$assignment
    }
    foreach ($function in $ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]},$true)) {
      $name=$function.Name.ToLowerInvariant()
      if (-not $functions.ContainsKey($name)) { $functions[$name]=@() }
      $parameters=@($(if ($function.Parameters) { $function.Parameters } elseif ($function.Body.ParamBlock) { $function.Body.ParamBlock.Parameters }) | Where-Object { $null -ne $_ })
      $functions[$name]+=[pscustomobject]@{unit=$unit;parameters=$parameters;node=$function
        calls=@($function.Body.FindAll({param($n) $n -is [Management.Automation.Language.CommandAst]},$true))}
    }
  }
  # A guard name alone is not authority. Authenticate the actual owner's
  # fail-closed body and an unconditional import of that tracked module.
  $nonDispatchGuardValid=$false
  $guardImports=@{}
  $expectedGuard=@'
function Assert-NonDispatchLedgerPath {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$Path)
  $leaf=([IO.Path]::GetFileName($Path) -split ':',2)[0].TrimEnd(' ','.')
  if ([string]::Equals($leaf,'dispatch-log.jsonl',[StringComparison]::OrdinalIgnoreCase)) {
    throw 'DISPATCH_LEDGER_OWNER_REQUIRED'
  }
}
'@
  $tokens=$null;$errors=$null
  $expectedAst=[Management.Automation.Language.Parser]::ParseInput($expectedGuard,[ref]$tokens,[ref]$errors)
  $expectedBody=$expectedAst.EndBlock.Statements[0].Body
  if ($functions.ContainsKey('assert-nondispatchledgerpath') -and $functions['assert-nondispatchledgerpath'].Count -eq 1) {
    $target=$functions['assert-nondispatchledgerpath'][0]
    $nonDispatchGuardValid=$target.unit.path -ceq '.orchestrator/dispatch-ledger-reader.psm1' -and (TokenShape $target.node.Body) -ceq (TokenShape $expectedBody)
    $exported=$false
    foreach ($statement in $target.unit.ast.EndBlock.Statements) {
      if ($statement -isnot [Management.Automation.Language.PipelineAst] -or $statement.PipelineElements.Count -ne 1) { continue }
      $call=$statement.PipelineElements[0]
      if ($call -isnot [Management.Automation.Language.CommandAst] -or $call.GetCommandName() -ine 'Export-ModuleMember' -or $call.CommandElements.Count -ne 3) { continue }
      $parameter=$call.CommandElements[1];$names=$call.CommandElements[2]
      if ($parameter -isnot [Management.Automation.Language.CommandParameterAst] -or $parameter.ParameterName -ine 'Function') { continue }
      $values=if ($names -is [Management.Automation.Language.ArrayLiteralAst]) { @($names.Elements) } else { @($names) }
      if (@($values | Where-Object { $_ -isnot [Management.Automation.Language.StringConstantExpressionAst] }).Count -eq 0 -and 'Assert-NonDispatchLedgerPath' -cin @($values | ForEach-Object Value)) { $exported=$true }
    }
    $nonDispatchGuardValid=$nonDispatchGuardValid -and $exported
  }
  if ($nonDispatchGuardValid) {
    $ownerPath=[IO.Path]::GetFullPath((Join-Path $Root '.orchestrator/dispatch-ledger-reader.psm1'))
    foreach ($unit in $units | Where-Object { -not $_.test -and $_.ast }) {
      foreach ($statement in $unit.ast.EndBlock.Statements) {
        if ($statement -isnot [Management.Automation.Language.PipelineAst] -or $statement.PipelineElements.Count -ne 1) { continue }
        $call=$statement.PipelineElements[0]
        if ($call -isnot [Management.Automation.Language.CommandAst] -or $call.GetCommandName() -ine 'Import-Module' -or $call.CommandElements.Count -lt 2) { continue }
        $options=@($call.CommandElements | Select-Object -Skip 2)
        if (@($options | Where-Object { $_ -isnot [Management.Automation.Language.CommandParameterAst] -or $_.Argument -or $_.ParameterName -notin @('Force','DisableNameChecking') }).Count) { continue }
        $argument=$call.CommandElements[1]
        if ($argument -isnot [Management.Automation.Language.ParenExpressionAst] -or $argument.Pipeline.PipelineElements.Count -ne 1) { continue }
        $join=$argument.Pipeline.PipelineElements[0]
        if ($join -isnot [Management.Automation.Language.CommandAst] -or $join.GetCommandName() -ine 'Join-Path' -or $join.CommandElements.Count -ne 3) { continue }
        $base=$join.CommandElements[1];$leaf=$join.CommandElements[2]
        if ($base -isnot [Management.Automation.Language.VariableExpressionAst] -or $base.VariablePath.UserPath -ine 'PSScriptRoot' -or $leaf -isnot [Management.Automation.Language.StringConstantExpressionAst]) { continue }
        $directory=Split-Path -Parent (Join-Path $Root $unit.path)
        if ([IO.Path]::GetFullPath((Join-Path $directory $leaf.Value)) -ceq $ownerPath -and -not $guardImports.ContainsKey($unit.path)) { $guardImports[$unit.path]=$statement.Extent.EndOffset }
      }
    }
  }
  Write-Verbose 'Ledger census: resolving script aliases'
  $changed=$true
  while ($changed) {
    $changed=$false
    foreach ($unit in $units | Where-Object { -not $_.test -and $_.ast }) {
      foreach ($assignment in $unit.assignments | Where-Object { $_.Left -is [Management.Automation.Language.VariableExpressionAst] }) {
        if (AddScriptAlias (Key $assignment.Left $unit) @(ScriptNames $assignment.Right $unit)) { $changed=$true }
      }
      foreach ($parameter in $unit.parameters) {
        if (AddScriptAlias (Key $parameter.Name $unit) @(ScriptNames $parameter.DefaultValue $unit)) { $changed=$true }
      }
    }
  }
  Write-Verbose 'Ledger census: resolving data functions'
  # A reader's output is row data, not a path alias. Derive that partition
  # transitively so a transcript selected by a dispatch row is not mistaken
  # for the canonical ledger itself. Literal path/filter scriptblocks are
  # evaluated in their own AST scopes, never as the pipeline's return value.
  $changed=$true;$dataRound=0
  while ($changed) {
    $dataRound++
    Write-Verbose "Ledger census: data function round $dataRound"
    $changed=$false
    foreach ($name in @($functions.Keys)) {
      foreach ($target in $functions[$name]) {
        $calls=$target.calls
        if (@($calls | Where-Object { $dataFunctions.Contains((CommandName $_ $target.unit)) }).Count -and $dataFunctions.Add($name)) { $changed=$true }
      }
    }
  }
  # Monotone fixed point over assignments, foreach bindings and real function
  # arguments. No path-name allowlist and no named-reader-only file selection.
  $changed=$true;$factRound=0
  while ($changed) {
    $factRound++
    Write-Verbose "Ledger census: provenance round $factRound"
    $changed=$false
    foreach ($unit in $units | Where-Object { -not $_.test -and $_.ast }) {
      Write-Verbose "Ledger census: provenance $factRound $($unit.path)"
      foreach ($assignment in $unit.assignments) {
        if ($assignment.Left -is [Management.Automation.Language.VariableExpressionAst]) {
          if (-not $assignmentShapes.ContainsKey($assignment)) {
            $assignmentShapes[$assignment]=@{
              dataCall=$assignment.Right.Find({param($n) $n -is [Management.Automation.Language.CommandAst] -and $dataFunctions.Contains((CommandName $n $unit))},$true)
              dataRead=$assignment.Right.Find({param($n) $n -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Member.Value -match '^Read(All|Lines)' -and $n.Expression -is [Management.Automation.Language.TypeExpressionAst] -and $n.Expression.TypeName.FullName -match '^(System\.)?IO\.File$'},$true)
              type=$assignment.Right.Find({param($n) $n -is [Management.Automation.Language.TypeExpressionAst]},$true)
            }
          }
          $dataCall=$assignmentShapes[$assignment].dataCall;$dataRead=$assignmentShapes[$assignment].dataRead
          if (-not $dataCall -and -not $dataRead -and (AddFact (Key $assignment.Left $unit) (Fact $assignment.Right $unit))) { $changed=$true }
          $type=$assignmentShapes[$assignment].type
          # Only a type-valued alias has static members. The result of
          # [IO.File]::Open(...) is a stream, not an alias for IO.File.
          if ($type -and $assignment.Right.Extent.Text.Trim() -ceq $type.Extent.Text) {
            $types[(Key $assignment.Left $unit)]=$type.TypeName.FullName
          }
        }
      }
      foreach ($parameter in $unit.parameters) {
        if (AddFact (Key $parameter.Name $unit) (Fact $parameter.DefaultValue $unit)) { $changed=$true }
      }
      foreach ($loop in $unit.loops) {
        if (AddFact (Key $loop.Variable $unit) (Fact $loop.Condition $unit)) { $changed=$true }
      }
      foreach ($call in $unit.calls) {
        $name=CommandName $call $unit
        if ($name -match '^read-dispatch(ledger(snapshot|lines|bytes)|counthistory)$|^read-exactheadreviewhistory$') {
          $argument=$null
          for ($i=1;$i -lt $call.CommandElements.Count;$i++) {
            $element=$call.CommandElements[$i]
            if ($element -is [Management.Automation.Language.CommandParameterAst] -and $element.ParameterName -ieq 'Path') {
              $argument=if ($element.Argument) { $element.Argument } else { $call.CommandElements[$i+1] };break
            }
          }
          if (-not $argument -and $call.CommandElements.Count -gt 1 -and $call.CommandElements[1] -isnot [Management.Automation.Language.CommandParameterAst]) { $argument=$call.CommandElements[1] }
          if ($argument -and (Fact $argument $unit) -eq 0) {
            foreach ($variable in $argument.FindAll({param($n) $n -is [Management.Automation.Language.VariableExpressionAst]},$true)) {
              if (AddFact (Key $variable $unit) 1) { $changed=$true }
            }
          }
        }
        if (-not $functions.ContainsKey($name)) { continue }
        foreach ($target in $functions[$name]) {
          $bound=Arguments $call $target.parameters
          foreach ($parameter in $target.parameters) {
            $p=$parameter.Name.VariablePath.UserPath.ToLowerInvariant()
            if ($bound.ContainsKey($p) -and (AddFact (Key $parameter.Name $target.unit) (Fact $bound[$p] $unit))) { $changed=$true }
            if ($bound.ContainsKey($p) -and (AddScriptAlias (Key $parameter.Name $target.unit) @(ScriptNames $bound[$p] $unit))) { $changed=$true }
          }
        }
      }
    }
  }
  $contentNames=@('get-content')+@(Get-Alias -Definition Get-Content -ErrorAction SilentlyContinue | ForEach-Object Name)
  Write-Verbose 'Ledger census: discovering command families'
  $knownCommands=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  foreach ($command in Get-Command -CommandType Cmdlet,Application -ListImported) { [void]$knownCommands.Add($command.Name) }
  foreach ($unit in $units | Where-Object ast) {
    foreach ($alias in $unit.ast.FindAll({param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -in @('Set-Alias','New-Alias')},$true)) {
      $values=@{};$position=0
      for ($i=1;$i -lt $alias.CommandElements.Count;$i++) {
        $element=$alias.CommandElements[$i]
        if ($element -is [Management.Automation.Language.CommandParameterAst]) {
          $key=$element.ParameterName.ToLowerInvariant()
          if ($i+1 -lt $alias.CommandElements.Count -and $alias.CommandElements[$i+1] -is [Management.Automation.Language.StringConstantExpressionAst]) { $i++;$values[$key]=$alias.CommandElements[$i].Value }
        } elseif ($element -is [Management.Automation.Language.StringConstantExpressionAst] -and $position -lt 2) { $values[@('name','value')[$position]]=$element.Value;$position++ }
      }
      if ($values['value'] -in $contentNames -and $values['name']) { $contentNames+=$values['name'] }
    }
  }
  foreach ($unit in $units) {
    Write-Verbose "Ledger census: classifying $($unit.path)"
    $nodes=if ($unit.ast) { @($unit.ast.FindAll({param($n) $n -is [Management.Automation.Language.InvokeMemberExpressionAst] -or
      $n -is [Management.Automation.Language.CommandAst] -or $n -is [Management.Automation.Language.StringConstantExpressionAst] -or
      $n -is [Management.Automation.Language.ExpandableStringExpressionAst]},$true)) } else { @() }
    foreach ($node in $nodes) {
      $family=$null;$role=$null;$argument=$node;$owner=$false;$unknown=$false
      if ($node -is [Management.Automation.Language.InvokeMemberExpressionAst]) {
        $type=if ($node.Expression -is [Management.Automation.Language.TypeExpressionAst]) { $node.Expression.TypeName.FullName }
          elseif ($node.Expression -is [Management.Automation.Language.VariableExpressionAst]) {
            $key=Key $node.Expression $unit
            if ($types.ContainsKey($key)) { $types[$key] }
            else { $types["$($unit.path)::script::$($node.Expression.VariablePath.UserPath.ToLowerInvariant())"] }
          }
          else { '' }
        if ($type -notmatch '^(System\.)?(IO\.)?(File|FileStream|StreamReader)$') {
          if ($node.Static -and $node.Member.Value -match '(?i)read|open' -and
              (((Fact $node $unit) -band 1) -or ($node.Arguments.Count -and -not (NonLedgerPath $node.Arguments[0] $unit)))) {
            $rows.Add([pscustomobject]@{path=$unit.path;line=$node.Extent.StartLineNumber;family='unknown-static-type';role='unclassified';authority='indeterminate';owner=$false;test=$unit.test;handled=$false})
          }
          continue
        }
        $method=$node.Member.Value
        $argument=if ($node.Arguments.Count) { $node.Arguments[0] } else { $node }
        $family=if ($type -match '(FileStream|StreamReader)$') { $Matches[1] } else { "IO.File.$method" }
        if ($family -match '^IO\.File\.(Exists|Delete|Move|Copy|Replace|Write.*|Append.*|Create.*|OpenWrite|Get.*|Set.*)$') { $role='writer' }
        elseif ($family -match '^IO\.File\.(Open|OpenRead|OpenText|ReadLines|ReadAllLines|ReadAllText|ReadAllBytes)$|^(StreamReader|FileStream)$') {
          $role='reader'
          if ($family -in @('IO.File.Open','FileStream')) {
            $mode=if ($node.Arguments.Count -gt 1) { $node.Arguments[1] }
            $access=if ($node.Arguments.Count -gt 2) { $node.Arguments[2] }
            $writeMode=$mode -is [Management.Automation.Language.MemberExpressionAst] -and $mode.Static -and
              $mode.Expression -is [Management.Automation.Language.TypeExpressionAst] -and $mode.Expression.TypeName.FullName -match '^(System\.)?IO\.FileMode$' -and $mode.Member.Value -in @('Create','CreateNew','Append')
            $writeAccess=$access -is [Management.Automation.Language.MemberExpressionAst] -and $access.Static -and
              $access.Expression -is [Management.Automation.Language.TypeExpressionAst] -and $access.Expression.TypeName.FullName -match '^(System\.)?IO\.FileAccess$' -and $access.Member.Value -eq 'Write'
            if ($writeMode -or $writeAccess) { $role='writer' }
          }
        } else { $role='unclassified';$unknown=$true }
        $container=$node.Parent
        while ($container -and $container -isnot [Management.Automation.Language.FunctionDefinitionAst]) { $container=$container.Parent }
        $owner=$unit.path -ceq '.orchestrator/dispatch-ledger-reader.psm1' -and $container -and
          $container.Name -ceq 'Read-DispatchLedgerSnapshot' -and $family -ceq 'IO.File.Open' -and
          $node.Extent.Text -match 'FileShare\]\s*::\s*ReadWrite'
      } elseif ($node -is [Management.Automation.Language.CommandAst]) {
        $name=CommandName $node $unit
        if ($name -in $contentNames) { $family='Get-Content';$role='reader' }
        elseif ($name -eq 'new-object' -and $node.Extent.Text -match '(?i)(System\.)?(IO\.)?(FileStream|StreamReader)') { $family=$Matches[3];$role='reader' }
        elseif ($name -match '^read-dispatch(ledger(snapshot|lines|bytes)|counthistory)$|^read-exactheadreviewhistory$') { $family='owner-api';$role='reader';$owner=$true }
        else { $family=$name;$role='path-forwarder' }
        $argument=$node
      } else {
        # Embedded C# is inspected as code shape, not a comment/path allowlist.
        $text=$node.Value
        $nativeMatches=@([regex]::Matches($text,'\b(?:File\s*\.\s*(?<method>\w+)\s*\(|new\s+(?<type>FileStream|StreamReader)\s*\()'))
        $unclassifiedNative=$text -match '(?i)\.\s*\w*(?:read|open)\w*\s*\(|\busing\s+(?:static\s+|\w+\s*=\s*)(?:System\.)?IO\.(?:File|FileStream|StreamReader)\b'
        $dispatchContext=$false
        if ($nativeMatches.Count -or $unclassifiedNative) {
          if ($unit.test) {
            # Fixtures are report-only: inventory native shapes without an
            # interprocedural proof over their synthetic source strings.
            $dispatchContext=$true
          } else {
            $context=$node.Parent
            while ($context.Parent -and $context -isnot [Management.Automation.Language.FunctionDefinitionAst]) { $context=$context.Parent }
            $dispatchContext=((Fact $context $unit) -band 1) -ne 0 -or $text -match 'dispatch-log(?:\\?\.)jsonl'
          }
        }
        if ($text -match '\b(?:File\s*\.|new\s+(?:FileStream|StreamReader)\s*\()') {
          foreach ($match in $nativeMatches) {
            $method=$match.Groups['method'].Value
            $embeddedRole=if ($method -match '^(Exists|Delete|Move|Copy|Replace|Write.*|Append.*|Create.*|OpenWrite|Get.*|Set.*)$') { 'writer' }
              elseif ($match.Groups['type'].Success -or $method -match '^(Open|OpenRead|OpenText|ReadLines|ReadAllLines|ReadAllText|ReadAllBytes)$') { 'reader' }
              else { 'unclassified' }
            $rows.Add([pscustomobject]@{path=$unit.path;line=$node.Extent.StartLineNumber+($text.Substring(0,$match.Index).Split("`n").Count-1)
              family=('embedded-C#.'+$(if ($match.Groups['method'].Success) {'File.'+$match.Groups['method'].Value} else {$match.Groups['type'].Value}))
              role=$embeddedRole;authority=$(if ($dispatchContext) {'dispatch'} elseif ($embeddedRole -eq 'writer') {'non-ledger'} else {'indeterminate'})
              owner=$false;test=$unit.test;handled=($embeddedRole -eq 'writer')})
          }
        }
        # Unknown embedded readers remain candidates even when their receiver
        # is an alias, using-static import, or an unclassified native family.
        # Do not pretend that recognizing Add-Type proves its payload harmless.
        if (-not $nativeMatches.Count -and $unclassifiedNative) {
          $rows.Add([pscustomobject]@{path=$unit.path;line=$node.Extent.StartLineNumber
            family='embedded-C#.unclassified';role='unclassified';authority='indeterminate';owner=$false;test=$unit.test;handled=$false})
        }
        if ($text -match 'dispatch-log\\\.jsonl|cost-ledger\\\.jsonl') {
          $rows.Add([pscustomobject]@{path=$unit.path;line=$node.Extent.StartLineNumber;family='pattern';role='retention-pattern';authority='dispatch/cost';owner=$false;test=$unit.test;handled=$true})
        }
        continue
      }
      $mask=Fact $argument $unit
      $pathArgument=if ($family -eq 'Get-Content') { ReaderPath $argument } elseif ($argument -isnot [Management.Automation.Language.CommandAst]) { $argument } else { $null }
      # Inventory every native I/O shape, including non-ledger exclusions.
      # Only path-forwarders with no ledger provenance are irrelevant.
      if ($mask -eq 0 -and $role -eq 'path-forwarder' -and $family -ne 'owner-api') { continue }
      # A branch flag (or a mention in its body) does not constrain the path.
      # Mixed helpers stay candidates until an actual path exclusion is proved.
      $authority=if ($family -eq 'owner-api') {'dispatch'} elseif ($role -eq 'reader' -and (HasPathGuard $node $pathArgument $unit)) {
        if ($mask -eq 2) { 'cost' } else { 'non-ledger' }
      } elseif ($mask -eq 2) {
        if ($role -eq 'reader' -and -not (NonLedgerPath $pathArgument $unit)) { 'indeterminate' } else { 'cost' }
      } elseif ($mask -eq 0) {
        if ($role -eq 'reader' -and -not (NonLedgerPath $pathArgument $unit)) { 'indeterminate' } else { 'non-ledger' }
      } elseif ($mask -band 1) {'dispatch'} else {'indeterminate'}
      if ($role -eq 'path-forwarder' -and $family -eq 'new-object' -and ($mask -band 1)) { $role='unclassified';$unknown=$true }
      if ($role -eq 'path-forwarder' -and $family -in @('invoke-expression','iex') -and ($mask -band 1)) { $role='unclassified';$unknown=$true }
      if ($role -eq 'path-forwarder' -and -not $functions.ContainsKey($family) -and -not $knownCommands.Contains($family) -and -not $trackedScripts.Contains($family)) { $role='unclassified';$unknown=$true }
      if ($role -eq 'path-forwarder' -and $functions.ContainsKey($family) -and ($mask -band 1)) {
        foreach ($target in $functions[$family]) {
          if (@($target.parameters | Where-Object { $_.Name.VariablePath.UserPath -ieq 'DispatchHistory' }).Count -and
              -not @($node.CommandElements | Where-Object { $_ -is [Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -ieq 'DispatchHistory' }).Count) {
            $role='unclassified';$unknown=$true
          }
        }
      }
      $handled=-not $unknown -and $authority -ne 'indeterminate' -and ($role -ne 'reader' -or $owner -or $authority -in @('cost','non-ledger'))
      if ($role -eq 'path-forwarder' -and -not $family) { $role='unclassified';$handled=$false }
      $rows.Add([pscustomobject]@{path=$unit.path;line=$node.Extent.StartLineNumber;family=$family;role=$role;authority=$authority;owner=$owner;test=$unit.test;handled=$handled})
    }
    if (-not $unit.ast -and $unit.source -match 'dispatch-log(?:\\?\.)jsonl') {
      # A newly tracked native source cannot evade the PowerShell grammar.
      $rows.Add([pscustomobject]@{path=$unit.path;line=1;family='native-source';role='unclassified';authority='indeterminate';owner=$false;test=$unit.test;handled=$false})
    }
  }
  foreach ($key in $SourceOverride.Keys) { if ($key -cnotin $paths) { throw "LEDGER_CENSUS_UNTRACKED_OVERRIDE:$key" } }
  $head=(& git -C $Root rev-parse HEAD)
  if ($LASTEXITCODE -ne 0 -or $head -cnotmatch '^[a-f0-9]{40}$') { throw 'LEDGER_CENSUS_HEAD_MISSING' }
  $digests=@($units | ForEach-Object { [pscustomobject]@{path=$_.path;sha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($_.source))).ToLowerInvariant()} })
  [pscustomobject]@{schemaVersion='dispatch-ledger-census/v1';sourceHead=$head;sourceDigests=$digests;scanned=$units.Count;total=$paths.Count
    rows=$rows.ToArray();violations=@($rows | Where-Object { -not $_.test -and -not $_.handled })}
}

Export-ModuleMember -Function Get-LedgerReaderCensus
