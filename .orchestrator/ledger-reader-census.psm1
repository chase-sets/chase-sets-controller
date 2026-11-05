# Static, tracked-source census. Never loads or executes the inspected scripts.
function Get-LedgerReaderCensus {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$Root,[hashtable]$SourceOverride=@{})
  $paths=@(& git -C $Root ls-files -- '*.ps1' '*.psm1' '*.cs')
  if ($LASTEXITCODE -ne 0 -or -not $paths.Count) { throw 'LEDGER_CENSUS_INVENTORY_MISSING' }
  $units=[Collections.Generic.List[object]]::new();$functions=@{};$facts=@{};$types=@{}
  $scriptAliases=@{};$trackedScripts=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  $dataFunctions=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  foreach ($name in @('read-dispatchledgersnapshot','read-dispatchledgerlines','read-dispatchledgerbytes','read-dispatchcounthistory','read-exactheadreviewhistory')) { [void]$dataFunctions.Add($name) }
  $rows=[Collections.Generic.List[object]]::new()
  function Scope($Node,$Unit) {
    $parent=$Node.Parent
    while ($null -ne $parent) {
      if ($parent -is [Management.Automation.Language.FunctionDefinitionAst]) { return "$($Unit.path)::$($parent.Extent.StartOffset)" }
      $parent=$parent.Parent
    }
    return "$($Unit.path)::script"
  }
  function Key($Node,$Unit) {
    $name=$Node.VariablePath.UserPath.ToLowerInvariant()
    if ($name -match '^(script|global):(.+)$') { return "$($Unit.path)::script::$($Matches[2])" }
    return (Scope $Node $Unit)+'::'+($name -replace '^(local|private):','')
  }
  function Fact($Node,$Unit) {
    if ($null -eq $Node) { return 0 }
    $mask=0
    foreach ($part in @($Node.FindAll({param($n) $n -is [Management.Automation.Language.StringConstantExpressionAst] -or
        $n -is [Management.Automation.Language.ExpandableStringExpressionAst] -or $n -is [Management.Automation.Language.VariableExpressionAst]},$true))) {
      $ancestor=$part;$nested=$false
      while ($ancestor -and $ancestor -ne $Node) {
        if ($ancestor -is [Management.Automation.Language.ScriptBlockExpressionAst] -or $ancestor -is [Management.Automation.Language.FunctionDefinitionAst]) { $nested=$true;break }
        $ancestor=$ancestor.Parent
      }
      if ($nested) { continue }
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
    foreach ($part in $Node.FindAll({param($n) $n -is [Management.Automation.Language.StringConstantExpressionAst] -or $n -is [Management.Automation.Language.VariableExpressionAst]},$true)) {
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
    $unit=[pscustomobject]@{path=$path;source=$source;test=$test;ast=$ast};$units.Add($unit)
    if ($test) { continue }
    foreach ($function in $ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]},$true)) {
      $name=$function.Name.ToLowerInvariant()
      if (-not $functions.ContainsKey($name)) { $functions[$name]=@() }
      $parameters=@($(if ($function.Parameters) { $function.Parameters } elseif ($function.Body.ParamBlock) { $function.Body.ParamBlock.Parameters }) | Where-Object { $null -ne $_ })
      $functions[$name]+=[pscustomobject]@{unit=$unit;parameters=$parameters;node=$function}
    }
  }
  $changed=$true
  while ($changed) {
    $changed=$false
    foreach ($unit in $units | Where-Object { -not $_.test -and $_.ast }) {
      foreach ($assignment in $unit.ast.FindAll({param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left -is [Management.Automation.Language.VariableExpressionAst]},$true)) {
        if (AddScriptAlias (Key $assignment.Left $unit) @(ScriptNames $assignment.Right $unit)) { $changed=$true }
      }
      foreach ($parameter in $unit.ast.FindAll({param($n) $n -is [Management.Automation.Language.ParameterAst]},$true)) {
        if (AddScriptAlias (Key $parameter.Name $unit) @(ScriptNames $parameter.DefaultValue $unit)) { $changed=$true }
      }
    }
  }
  # A reader's output is row data, not a path alias. Derive that partition
  # transitively so a transcript selected by a dispatch row is not mistaken
  # for the canonical ledger itself. Literal path/filter scriptblocks are
  # evaluated in their own AST scopes, never as the pipeline's return value.
  $changed=$true
  while ($changed) {
    $changed=$false
    foreach ($name in @($functions.Keys)) {
      foreach ($target in $functions[$name]) {
        $calls=@($target.node.Body.FindAll({param($n) $n -is [Management.Automation.Language.CommandAst]},$true))
        if (@($calls | Where-Object { $dataFunctions.Contains((CommandName $_ $target.unit)) }).Count -and $dataFunctions.Add($name)) { $changed=$true }
      }
    }
  }
  # Monotone fixed point over assignments, foreach bindings and real function
  # arguments. No path-name allowlist and no named-reader-only file selection.
  $changed=$true
  while ($changed) {
    $changed=$false
    foreach ($unit in $units | Where-Object { -not $_.test -and $_.ast }) {
      foreach ($assignment in $unit.ast.FindAll({param($n) $n -is [Management.Automation.Language.AssignmentStatementAst]},$true)) {
        if ($assignment.Left -is [Management.Automation.Language.VariableExpressionAst]) {
          $dataCall=$assignment.Right.Find({param($n) $n -is [Management.Automation.Language.CommandAst] -and $dataFunctions.Contains((CommandName $n $unit))},$true)
          $dataRead=$assignment.Right.Find({param($n) $n -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Member.Value -match '^Read(All|Lines)' -and $n.Expression -is [Management.Automation.Language.TypeExpressionAst] -and $n.Expression.TypeName.FullName -match '^(System\.)?IO\.File$'},$true)
          if (-not $dataCall -and -not $dataRead -and (AddFact (Key $assignment.Left $unit) (Fact $assignment.Right $unit))) { $changed=$true }
          $type=$assignment.Right.Find({param($n) $n -is [Management.Automation.Language.TypeExpressionAst]},$true)
          # Only a type-valued alias has static members. The result of
          # [IO.File]::Open(...) is a stream, not an alias for IO.File.
          if ($type -and $assignment.Right.Extent.Text.Trim() -ceq $type.Extent.Text) {
            $types[(Key $assignment.Left $unit)]=$type.TypeName.FullName
          }
        }
      }
      foreach ($parameter in $unit.ast.FindAll({param($n) $n -is [Management.Automation.Language.ParameterAst]},$true)) {
        if (AddFact (Key $parameter.Name $unit) (Fact $parameter.DefaultValue $unit)) { $changed=$true }
      }
      foreach ($loop in $unit.ast.FindAll({param($n) $n -is [Management.Automation.Language.ForEachStatementAst]},$true)) {
        if (AddFact (Key $loop.Variable $unit) (Fact $loop.Condition $unit)) { $changed=$true }
      }
      foreach ($call in $unit.ast.FindAll({param($n) $n -is [Management.Automation.Language.CommandAst]},$true)) {
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
          if ($node.Static -and $node.Member.Value -match '(?i)read|open' -and ((Fact $node $unit) -band 1)) {
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
          if ($node.Extent.Text -match 'FileAccess\]\s*::\s*Write\b|FileMode\]\s*::\s*(Create|CreateNew|Append)\b') { $role='writer' }
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
        if ($text -match '\b(?:File\s*\.|new\s+(?:FileStream|StreamReader)\s*\()') {
          foreach ($match in [regex]::Matches($text,'\b(?:File\s*\.\s*(?<method>\w+)\s*\(|new\s+(?<type>FileStream|StreamReader)\s*\()')) {
            $context=$node.Parent
            while ($context.Parent -and $context -isnot [Management.Automation.Language.FunctionDefinitionAst]) { $context=$context.Parent }
            if (((Fact $context $unit) -band 1) -eq 0 -and $text -notmatch 'dispatch-log(?:\\?\.)jsonl') { continue }
            $rows.Add([pscustomobject]@{path=$unit.path;line=$node.Extent.StartLineNumber+($text.Substring(0,$match.Index).Split("`n").Count-1)
              family=('embedded-C#.'+$(if ($match.Groups['method'].Success) {'File.'+$match.Groups['method'].Value} else {$match.Groups['type'].Value}))
              role='reader';authority='dispatch';owner=$false;test=$unit.test;handled=$false})
          }
        }
        if ($text -match 'dispatch-log\\\.jsonl|cost-ledger\\\.jsonl') {
          $rows.Add([pscustomobject]@{path=$unit.path;line=$node.Extent.StartLineNumber;family='pattern';role='retention-pattern';authority='dispatch/cost';owner=$false;test=$unit.test;handled=$true})
        }
        continue
      }
      $mask=Fact $argument $unit
      # Inventory every native I/O shape, including non-ledger exclusions.
      # Only path-forwarders with no ledger provenance are irrelevant.
      if ($mask -eq 0 -and $role -eq 'path-forwarder' -and $family -ne 'owner-api') { continue }
      # Mixed dispatch/cost helpers must explicitly separate the dispatch branch.
      $costBranch=$false;$nonLedgerBranch=$false
      if ($mask -band 3) {
        $parent=$node.Parent
        while ($parent) {
          if ($parent -is [Management.Automation.Language.IfStatementAst] -and $parent.Extent.Text -match '\$DispatchHistory') {
            $nonLedgerBranch=$parent.ElseClause -and $node.Extent.StartOffset -ge $parent.ElseClause.Extent.StartOffset
            $costBranch=$nonLedgerBranch -and ($mask -band 2)
            break
          }
          $parent=$parent.Parent
        }
      }
      $authority=if ($costBranch -or $mask -eq 2) {'cost'} elseif ($nonLedgerBranch -or $mask -eq 0) {'non-ledger'} elseif (($mask -band 1) -or $family -eq 'owner-api') {'dispatch'} else {'indeterminate'}
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
