# Static, tracked-source census. Never loads or executes the inspected scripts.
Import-Module (Join-Path $PSScriptRoot 'dispatch-ledger-reader.psm1') -Global -DisableNameChecking
if (-not ('ChaseSets.LedgerCensus.AstSelectionV1' -as [type])) {
  Add-Type -TypeDefinition @'
using System;
using System.Linq;
using System.Management.Automation.Language;
namespace ChaseSets.LedgerCensus {
  public static class AstSelectionV1 {
    public static Ast[] Find(Ast root, params Type[] kinds) {
      return root.FindAll(node => {
        foreach (var kind in kinds) if (kind.IsInstanceOfType(node)) return true;
        return false;
      }, true).ToArray();
    }
  }
}
'@
}

function Find-LedgerCensusAst($Node,[type[]]$Kinds) {
  [ChaseSets.LedgerCensus.AstSelectionV1]::Find($Node,$Kinds)
}

function Get-LedgerEmbeddedFileStreams([string]$Text) {
  $sites=[Collections.Generic.List[object]]::new()
  $parsed=$false
  try {
    # Use the compiler shipped with PowerShell for syntax/binding only. Never
    # emit an assembly or execute the inspected payload. Unavailable or invalid
    # binding grants no writer exemption; the caller retains its native census.
    if (-not ('Microsoft.CodeAnalysis.CSharp.CSharpSyntaxTree' -as [type])) {
      [void][Reflection.Assembly]::LoadFrom((Join-Path $PSHOME 'Microsoft.CodeAnalysis.dll'))
      [void][Reflection.Assembly]::LoadFrom((Join-Path $PSHOME 'Microsoft.CodeAnalysis.CSharp.dll'))
    }
    $tree=[Microsoft.CodeAnalysis.CSharp.CSharpSyntaxTree]::ParseText($Text)
    $parsed=$true
    foreach ($node in $tree.GetRoot().DescendantNodes()) {
      if ($node -is [Microsoft.CodeAnalysis.CSharp.Syntax.ObjectCreationExpressionSyntax] -and
          $node.Type.ToString() -match '^(?:global::)?(?:System\s*\.\s*IO\s*\.\s*)?FileStream$') {
        $sites.Add([pscustomobject]@{index=$node.SpanStart;writer=$false;node=$node})
      }
    }
    if (-not $sites.Count) { return [pscustomobject]@{parsed=$true;sites=@()} }
    $references=[Collections.Generic.List[Microsoft.CodeAnalysis.MetadataReference]]::new()
    foreach ($path in ([AppContext]::GetData('TRUSTED_PLATFORM_ASSEMBLIES') -split [IO.Path]::PathSeparator)) {
      $references.Add([Microsoft.CodeAnalysis.MetadataReference]::CreateFromFile($path))
    }
    $options=[Microsoft.CodeAnalysis.CSharp.CSharpCompilationOptions]::new([Microsoft.CodeAnalysis.OutputKind]::DynamicallyLinkedLibrary)
    $compilation=[Microsoft.CodeAnalysis.CSharp.CSharpCompilation]::Create('LedgerCensusBinding',[Microsoft.CodeAnalysis.SyntaxTree[]]@($tree),$references,$options)
    if (@($compilation.GetDiagnostics() | Where-Object Severity -EQ 'Error').Count) { return [pscustomobject]@{parsed=$true;sites=$sites.ToArray()} }
    $model=$compilation.GetSemanticModel($tree)
    foreach ($site in $sites) {
      $operation=$model.GetOperation($site.node)
      $constructor=$operation.Constructor
      if (-not $constructor -or $constructor.ContainingType.MetadataName -cne 'FileStream' -or
          $constructor.ContainingType.ContainingNamespace.ToString() -cne 'System.IO' -or
          $constructor.ContainingAssembly.Identity.Name -cne [IO.FileStream].Assembly.GetName().Name) { continue }
      foreach ($argument in $operation.Arguments) {
        $parameter=$argument.Parameter
        if ($parameter.Name -cne 'access' -or $parameter.Type.MetadataName -cne 'FileAccess' -or
            $parameter.Type.ContainingNamespace.ToString() -cne 'System.IO' -or
            $parameter.Type.ContainingAssembly.Identity.Name -cne [IO.FileAccess].Assembly.GetName().Name) { continue }
        $constant=$model.GetConstantValue($argument.Value.Syntax)
        if ($constant.HasValue -and $constant.Value -eq [int][IO.FileAccess]::Write) { $site.writer=$true }
      }
    }
  } catch {
    # Partial binding must not leak a positive decision from an earlier site.
    $parsed=$false
    foreach ($site in $sites) { $site.writer=$false }
  }
  return [pscustomobject]@{parsed=$parsed;sites=$sites.ToArray()}
}

function Get-LedgerReaderCensus {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$Root,[hashtable]$SourceOverride=@{})
  $paths=@(& git -C $Root ls-files -- ':(icase)*.ps1' ':(icase)*.psm1' ':(icase)*.cs')
  if ($LASTEXITCODE -ne 0 -or -not $paths.Count) { throw 'LEDGER_CENSUS_INVENTORY_MISSING' }
  Write-Verbose "Ledger census: parsing $($paths.Count) tracked sources"
  $units=[Collections.Generic.List[object]]::new();$functions=@{};$facts=@{};$types=@{}
  $variableKeys=@{};$factParts=@{};$scriptParts=@{};$assignmentShapes=@{};$literalFacts=@{}
  $pathAssignments=@{};$pathParameters=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  $stringParameters=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  $scriptAliases=@{};$trackedScripts=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  $dataFunctions=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  foreach ($name in @('read-dispatchledgersnapshot','read-dispatchledgerlines','read-dispatchledgerbytes','read-dispatchcounthistory','read-exactheadreviewhistory')) { [void]$dataFunctions.Add($name) }
  $rows=[Collections.Generic.List[object]]::new()
  $terminalTrapProof=@{}
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
    if (NonDispatchValuePath $Path $Unit) { return $true }
    if ($Unit.traps.Count) { return $false }
    if (-not $nonDispatchGuardValid -or -not $guardImports.ContainsKey($Unit.path) -or $guardImports[$Unit.path] -ge $Node.Extent.StartOffset -or $Path -isnot [Management.Automation.Language.VariableExpressionAst]) { return $false }
    if (-not $stringParameters.Contains((Key $Path $Unit))) { return $false }
    $statement=$Node
    while ($statement.Parent -and $statement.Parent -isnot [Management.Automation.Language.StatementBlockAst] -and $statement.Parent -isnot [Management.Automation.Language.NamedBlockAst]) { $statement=$statement.Parent }
    $block=$statement.Parent
    if (-not $block) { return $false }
    $index=$block.Statements.IndexOf($statement)
    if ($index -lt 1) { return $false }
    $previous=$block.Statements[$index-1]
    if ($previous -isnot [Management.Automation.Language.PipelineAst] -or $previous.Background -or $previous.PipelineElements.Count -ne 1) { return $false }
    $call=$previous.PipelineElements[0]
    if ($call -isnot [Management.Automation.Language.CommandAst] -or $call.Redirections.Count -or $call.GetCommandName() -cne 'dispatch-ledger-reader\Assert-NonDispatchLedgerPath' -or $call.CommandElements.Count -ne 3) { return $false }
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
  function InlineNonDispatchStreamReader($Node,$Unit) {
    # No stream-storage inference: accept only a directly constructed guarded
    # file stream or an exact data-only memory decoder. Native reads that feed
    # the bytes remain independently censused; this grants no path authority.
    if ($Node -isnot [Management.Automation.Language.InvokeMemberExpressionAst] -or -not $Node.Static -or
        $Node.GenericTypeArguments.Count -or $Node.NullConditional -or $Node.Member.Value -ine 'new' -or
        $Node.Expression -isnot [Management.Automation.Language.TypeExpressionAst] -or
        $Node.Expression.TypeName.FullName -notmatch '^(System\.)?IO\.StreamReader$' -or $Node.Arguments.Count -notin @(1,3)) { return $false }
    $stream=$Node.Arguments[0]
    if ($stream -isnot [Management.Automation.Language.InvokeMemberExpressionAst] -or -not $stream.Static -or
        $stream.GenericTypeArguments.Count -or $stream.NullConditional -or $stream.Member.Value -ine 'new' -or
        $stream.Expression -isnot [Management.Automation.Language.TypeExpressionAst]) { return $false }
    if ($stream.Expression.TypeName.FullName -match '^(System\.)?IO\.MemoryStream$') {
      if ($Node.Arguments.Count -ne 3 -or $stream.Arguments.Count -ne 2 -or ((Fact $Node $Unit) -band 5)) { return $false }
      $bytes=$stream.Arguments[0];$writable=$stream.Arguments[1]
      $encoding=$Node.Arguments[1];$detectBom=$Node.Arguments[2]
      return $bytes -is [Management.Automation.Language.VariableExpressionAst] -and
        $bytes.VariablePath.UserPath -match '^[a-zA-Z_][a-zA-Z0-9_]*$' -and
        $writable -is [Management.Automation.Language.VariableExpressionAst] -and $writable.VariablePath.UserPath -ieq 'false' -and
        $encoding -is [Management.Automation.Language.MemberExpressionAst] -and
        $encoding -isnot [Management.Automation.Language.InvokeMemberExpressionAst] -and $encoding.Static -and -not $encoding.NullConditional -and
        $encoding.Expression -is [Management.Automation.Language.TypeExpressionAst] -and
        $encoding.Expression.TypeName.FullName -match '^(System\.)?Text\.Encoding$' -and $encoding.Member.Value -ieq 'UTF8' -and
        $detectBom -is [Management.Automation.Language.VariableExpressionAst] -and $detectBom.VariablePath.UserPath -ieq 'true'
    }
    if ($Node.Arguments.Count -ne 1 -or $stream.Expression.TypeName.FullName -notmatch '^(System\.)?IO\.FileStream$' -or $stream.Arguments.Count -ne 4) { return $false }
    $enumTypes=@('FileMode','FileAccess','FileShare');$enumValues=@('Open','Read','ReadWrite')
    for ($index=0;$index -lt 3;$index++) {
      $value=$stream.Arguments[$index+1]
      if ($value -isnot [Management.Automation.Language.MemberExpressionAst] -or
          $value -is [Management.Automation.Language.InvokeMemberExpressionAst] -or -not $value.Static -or $value.NullConditional -or
          $value.Expression -isnot [Management.Automation.Language.TypeExpressionAst] -or
          $value.Expression.TypeName.FullName -notmatch ('^(System\.)?IO\.'+$enumTypes[$index]+'$') -or
          $value.Member.Value -ine $enumValues[$index]) { return $false }
    }
    return HasPathGuard $stream $stream.Arguments[0] $Unit
  }
  function Key($Node,$Unit) {
    if ($variableKeys.ContainsKey($Node)) { return $variableKeys[$Node] }
    $name=$Node.VariablePath.UserPath.ToLowerInvariant()
    $key=if ($name -match '^(script|global):(.+)$') { "$($Unit.path)::script::$($Matches[2])" }
      else { (Scope $Node $Unit)+'::'+($name -replace '^(local|private):','') }
    $variableKeys[$Node]=$key
    return $key
  }
  function LiteralString($Node,[int]$Depth=0) {
    if ($Depth -ge 12) { return $null }
    if ($Node -is [Management.Automation.Language.StringConstantExpressionAst]) { return $Node.Value }
    if ($Node -is [Management.Automation.Language.ParenExpressionAst]) {
      return LiteralString (SingleExpression $Node.Pipeline) ($Depth+1)
    }
    if ($Node -is [Management.Automation.Language.BinaryExpressionAst] -and $Node.Operator -eq [Management.Automation.Language.TokenKind]::Plus) {
      $left=LiteralString $Node.Left ($Depth+1);$right=LiteralString $Node.Right ($Depth+1)
      if ($null -ne $left -and $null -ne $right) { return ($left+$right) }
    }
    return $null
  }
  function LiteralNumericPlus($Node,[int]$Depth=0) {
    if ($Depth -ge 12 -or $null -eq $Node) { return $false }
    if ($Node -is [Management.Automation.Language.ConstantExpressionAst] -and $null -ne $Node.Value) {
      return [Type]::GetTypeCode($Node.Value.GetType()) -in @('Byte','SByte','Int16','UInt16','Int32','UInt32','Int64','UInt64','Single','Double','Decimal')
    }
    if ($Node -is [Management.Automation.Language.ParenExpressionAst]) {
      return LiteralNumericPlus (SingleExpression $Node.Pipeline) ($Depth+1)
    }
    if ($Node -is [Management.Automation.Language.BinaryExpressionAst] -and $Node.Operator -eq [Management.Automation.Language.TokenKind]::Plus) {
      return (LiteralNumericPlus $Node.Left ($Depth+1)) -and (LiteralNumericPlus $Node.Right ($Depth+1))
    }
    return $false
  }
  function Fact($Node,$Unit) {
    if ($null -eq $Node) { return 0 }
    $mask=0
    if (-not $factParts.ContainsKey($Node)) {
      $parts=@(Find-LedgerCensusAst $Node @([Management.Automation.Language.StringConstantExpressionAst],
          [Management.Automation.Language.ExpandableStringExpressionAst],[Management.Automation.Language.VariableExpressionAst],
          [Management.Automation.Language.BinaryExpressionAst],[Management.Automation.Language.UnaryExpressionAst],
          [Management.Automation.Language.InvokeMemberExpressionAst]))
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
        # Unresolved composition is uncertainty, not a safety proof.
        # Cache immutable syntax only; variable facts still flow to a fixed point.
        if ($part -is [Management.Automation.Language.BinaryExpressionAst]) {
          if (-not $literalFacts.ContainsKey($part)) {
            $literal=LiteralString $part
            $uncertain=$part.Operator -in @([Management.Automation.Language.TokenKind]::Format,
                [Management.Automation.Language.TokenKind]::Join,[Management.Automation.Language.TokenKind]::Ireplace,
                [Management.Automation.Language.TokenKind]::Creplace) -or
              ($null -eq $literal -and $part.Operator -eq [Management.Automation.Language.TokenKind]::Plus -and
               -not (LiteralNumericPlus $part))
            $literalFacts[$part]=@{value=$literal;uncertain=$uncertain}
          }
          $value=$literalFacts[$part].value
          if ($literalFacts[$part].uncertain) { $mask=$mask -bor 4 }
        } elseif ($part -is [Management.Automation.Language.UnaryExpressionAst]) {
          $value=$null
          if ($part.TokenKind -eq [Management.Automation.Language.TokenKind]::Join) { $mask=$mask -bor 4 }
        } elseif ($part -is [Management.Automation.Language.InvokeMemberExpressionAst]) {
          $value=$null
          if (-not $literalFacts.ContainsKey($part)) {
            $receiver=$part.Expression;$depth=0
            while ($receiver -is [Management.Automation.Language.ParenExpressionAst] -and $depth -lt 12) {
              $receiver=SingleExpression $receiver.Pipeline;$depth++
            }
            # Mutable receivers and exhausted/opaque wrappers are not purity
            # proofs. Cache syntax only; this can add uncertainty, never safety.
            $uncertain=$null -eq $receiver -or $receiver -is [Management.Automation.Language.ParenExpressionAst] -or
              $receiver -is [Management.Automation.Language.VariableExpressionAst] -or
              ($part.Static -and $receiver -is [Management.Automation.Language.TypeExpressionAst] -and
               $receiver.TypeName.FullName -match '^(System\.)?String$') -or
              ($receiver -is [Management.Automation.Language.ConvertExpressionAst] -and
               $receiver.Type.TypeName.FullName -match '^(System\.)?String$') -or
              $receiver -is [Management.Automation.Language.ExpandableStringExpressionAst] -or
              $null -ne (LiteralString $receiver)
            $literalFacts[$part]=@{uncertain=$uncertain}
          }
          if ($literalFacts[$part].uncertain) { $mask=$mask -bor 4 }
        } else {
          $value=$part.Value
          if ($part -is [Management.Automation.Language.ExpandableStringExpressionAst] -and $part.NestedExpressions.Count) { $mask=$mask -bor 4 }
        }
        if ($value -match '(?i)dispatch-log(?:\\?\.)jsonl') { $mask=$mask -bor 1 }
        if ($value -match '(?i)cost-ledger(?:\\?\.)jsonl') { $mask=$mask -bor 2 }
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
    if (NonDispatchValuePath $Node $Unit) { return $true }
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
  function SingleExpression($Node) {
    if ($Node -isnot [Management.Automation.Language.PipelineAst] -or $Node.Background -or $Node.PipelineElements.Count -ne 1) { return $null }
    $element=$Node.PipelineElements[0]
    if ($element -isnot [Management.Automation.Language.CommandExpressionAst] -or $element.Redirections.Count) { return $null }
    return $element.Expression
  }
  function TerminalUnitTrap($Unit) {
    if (-not $Unit.traps.Count) { return $true }
    if ($terminalTrapProof.ContainsKey($Unit.path)) { return $terminalTrapProof[$Unit.path] }
    # Only a single untyped script-level trap containing just a rethrow is proved.
    # Other statements can transfer control through opaque/transitive calls.
    # This proof is for the frozen value guard, never a separate assertion.
    $safe=& {
      if ($Unit.traps.Count -ne 1) { return $false }
      $trap=$Unit.traps[0]
      if ($trap.TrapType -or $trap.Parent -ne $Unit.ast.EndBlock -or $trap.Body.Statements.Count -ne 1) { return $false }
      $last=$trap.Body.Statements[0]
      if ($last -isnot [Management.Automation.Language.ThrowStatementAst]) { return $false }
      $exception=SingleExpression $last.Pipeline
      if ($exception -isnot [Management.Automation.Language.MemberExpressionAst] -or
          $exception -is [Management.Automation.Language.InvokeMemberExpressionAst] -or $exception.Static -or $exception.NullConditional -or
          $exception.Expression -isnot [Management.Automation.Language.VariableExpressionAst] -or
          $exception.Expression.VariablePath.UserPath -cne '_' -or
          $exception.Member -isnot [Management.Automation.Language.StringConstantExpressionAst] -or $exception.Member.Value -cne 'Exception') { return $false }
      return $true
    }
    $terminalTrapProof[$Unit.path]=$safe
    return $safe
  }
  function NonDispatchValuePath($Node,$Unit) {
    if (-not $nonDispatchValueValid -or -not $Node -or -not (TerminalUnitTrap $Unit) -or -not $guardImports.ContainsKey($Unit.path) -or $guardImports[$Unit.path] -ge $Node.Extent.StartOffset) { return $false }
    if ($Node -is [Management.Automation.Language.ParenExpressionAst]) { return NonDispatchValuePath $Node.Pipeline $Unit }
    if ($Node -is [Management.Automation.Language.PipelineAst] -and -not $Node.Background -and $Node.PipelineElements.Count -eq 1) { return NonDispatchValuePath $Node.PipelineElements[0] $Unit }
    if ($Node -isnot [Management.Automation.Language.CommandAst] -or $Node.Redirections.Count -or $Node.GetCommandName() -cne 'dispatch-ledger-reader\Get-NonDispatchLedgerPath' -or $Node.CommandElements.Count -ne 3) { return $false }
    $parameter=$Node.CommandElements[1];$value=$Node.CommandElements[2]
    return $parameter -is [Management.Automation.Language.CommandParameterAst] -and $parameter.ParameterName -ceq 'Path' -and -not $parameter.Argument -and
      $value -isnot [Management.Automation.Language.CommandParameterAst] -and -not ($value -is [Management.Automation.Language.VariableExpressionAst] -and $value.Splatted)
  }
  function CommandName($Node,$Unit) {
    $name=$Node.GetCommandName()
    if ($null -eq $name) {
      $head=$Node.CommandElements[0]
      foreach ($literal in (Find-LedgerCensusAst $head ([Management.Automation.Language.StringConstantExpressionAst]))) {
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
      $scriptParts[$Node]=@(Find-LedgerCensusAst $Node @([Management.Automation.Language.StringConstantExpressionAst],[Management.Automation.Language.VariableExpressionAst]))
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
    $source=if ($SourceOverride.ContainsKey($path)) { $SourceOverride[$path] } else { [IO.File]::ReadAllText((dispatch-ledger-reader\Get-NonDispatchLedgerPath -Path $full)) }
    $test=$path -match '(?i)(^|/)(fixtures|diagnostics)/|(?:\.test|\.check|\.test-support|-test-support|-fixture-harness|-test-fixture)\.ps1$|/issue-\d+-(?:discriminator|live-readonly-proof)\.ps1$'
    if ($path.EndsWith('.cs',[StringComparison]::OrdinalIgnoreCase)) { $units.Add([pscustomobject]@{path=$path;source=$source;test=$test;ast=$null});continue }
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors)
    if ($errors.Count) { throw "LEDGER_CENSUS_PARSE_FAILED:$path" }
    $unit=[pscustomobject]@{path=$path;source=$source;test=$test;ast=$ast
      assignments=@(if (-not $test) { Find-LedgerCensusAst $ast ([Management.Automation.Language.AssignmentStatementAst]) })
      parameters=@(if (-not $test) { Find-LedgerCensusAst $ast ([Management.Automation.Language.ParameterAst]) })
      traps=@(if (-not $test) { Find-LedgerCensusAst $ast ([Management.Automation.Language.TrapStatementAst]) })
      loops=@(if (-not $test) { Find-LedgerCensusAst $ast ([Management.Automation.Language.ForEachStatementAst]) })
      calls=@(if (-not $test) { Find-LedgerCensusAst $ast ([Management.Automation.Language.CommandAst]) })};$units.Add($unit)
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
    foreach ($function in (Find-LedgerCensusAst $ast ([Management.Automation.Language.FunctionDefinitionAst]))) {
      $name=$function.Name.ToLowerInvariant()
      if (-not $functions.ContainsKey($name)) { $functions[$name]=@() }
      $parameters=@($(if ($function.Parameters) { $function.Parameters } elseif ($function.Body.ParamBlock) { $function.Body.ParamBlock.Parameters }) | Where-Object { $null -ne $_ })
      $functions[$name]+=[pscustomobject]@{unit=$unit;parameters=$parameters;node=$function
        calls=@(Find-LedgerCensusAst $function.Body ([Management.Automation.Language.CommandAst]))}
    }
  }
  # The shared native open moved out of the snapshot reducer into a private
  # factory. Prove its signature and single return expression, not a matching
  # function name, file name, or ReadWrite mention elsewhere in a body.
  $factoryOpen=$null
  $factoryDefinitions=@(foreach ($name in $functions.Keys) {
    if (($name -split ':')[-1] -ieq 'Open-DispatchLedgerReadStream') { $functions[$name] }
  })
  if ($factoryDefinitions.Count -eq 1) {
    $target=$factoryDefinitions[0];$factory=$target.node
    $parameters=@($factory.Parameters)
    if ($factory.Name -ieq 'Open-DispatchLedgerReadStream' -and $target.unit.path -ceq '.orchestrator/dispatch-ledger-reader.psm1' -and $factory.Parent -eq $target.unit.ast.EndBlock -and
        -not $target.unit.traps.Count -and -not $factory.IsFilter -and -not $factory.IsWorkflow -and
        $parameters.Count -eq 1 -and $parameters[0].Name.VariablePath.UserPath -ceq 'Path' -and
        -not $parameters[0].DefaultValue -and $parameters[0].Attributes.Count -eq 1 -and
        $parameters[0].Attributes[0] -is [Management.Automation.Language.TypeConstraintAst] -and
        $parameters[0].Attributes[0].TypeName.FullName -ceq 'string' -and
        -not $factory.Body.ParamBlock -and -not $factory.Body.DynamicParamBlock -and -not $factory.Body.BeginBlock -and
        -not $factory.Body.ProcessBlock -and -not $factory.Body.CleanBlock -and $factory.Body.EndBlock.Statements.Count -eq 1) {
      $return=$factory.Body.EndBlock.Statements[0]
      if ($return -is [Management.Automation.Language.ReturnStatementAst] -and
          $return.Pipeline -is [Management.Automation.Language.PipelineAst] -and -not $return.Pipeline.Background -and
          $return.Pipeline.PipelineElements.Count -eq 1 -and
          $return.Pipeline.PipelineElements[0] -is [Management.Automation.Language.CommandExpressionAst] -and
          -not $return.Pipeline.PipelineElements[0].Redirections.Count) {
        $open=$return.Pipeline.PipelineElements[0].Expression
        if ($open -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $open.Static -and -not $open.GenericTypeArguments.Count -and
            $open.Expression -is [Management.Automation.Language.TypeExpressionAst] -and $open.Expression.TypeName.FullName -ceq 'IO.File' -and
            $open.Member -is [Management.Automation.Language.StringConstantExpressionAst] -and $open.Member.Value -ceq 'Open' -and
            $open.Arguments.Count -eq 4 -and $open.Arguments[0] -is [Management.Automation.Language.VariableExpressionAst] -and
            $open.Arguments[0].VariablePath.UserPath -ceq 'Path') {
          $valid=$true
          $enumTypes=@('IO.FileMode','IO.FileAccess','IO.FileShare');$members=@('Open','Read','ReadWrite')
          for ($i=0;$i -lt 3;$i++) {
            $value=$open.Arguments[$i+1]
            if ($value -isnot [Management.Automation.Language.MemberExpressionAst] -or $value -is [Management.Automation.Language.InvokeMemberExpressionAst] -or -not $value.Static -or
                $value.Expression -isnot [Management.Automation.Language.TypeExpressionAst] -or $value.Expression.TypeName.FullName -cne $enumTypes[$i] -or
                $value.Member -isnot [Management.Automation.Language.StringConstantExpressionAst] -or $value.Member.Value -cne $members[$i]) { $valid=$false;break }
          }
          if ($valid) { $factoryOpen=$open }
        }
      }
    }
  }
  # A guard name alone is not authority. Authenticate the actual owner's
  # fail-closed body and an unconditional import of that tracked module.
  $nonDispatchGuardValid=$false
  $nonDispatchValueValid=$false
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
    $exported=$false;$valueExported=$false
    foreach ($statement in $target.unit.ast.EndBlock.Statements) {
      if ($statement -isnot [Management.Automation.Language.PipelineAst] -or $statement.PipelineElements.Count -ne 1) { continue }
      $call=$statement.PipelineElements[0]
      if ($call -isnot [Management.Automation.Language.CommandAst] -or $call.GetCommandName() -ine 'Export-ModuleMember' -or $call.CommandElements.Count -ne 3) { continue }
      $parameter=$call.CommandElements[1];$names=$call.CommandElements[2]
      if ($parameter -isnot [Management.Automation.Language.CommandParameterAst] -or $parameter.ParameterName -ine 'Function') { continue }
      $values=if ($names -is [Management.Automation.Language.ArrayLiteralAst]) { @($names.Elements) } else { @($names) }
      if (@($values | Where-Object { $_ -isnot [Management.Automation.Language.StringConstantExpressionAst] }).Count -eq 0 -and 'Assert-NonDispatchLedgerPath' -cin @($values | ForEach-Object Value)) { $exported=$true }
      if (@($values | Where-Object { $_ -isnot [Management.Automation.Language.StringConstantExpressionAst] }).Count -eq 0 -and 'Get-NonDispatchLedgerPath' -cin @($values | ForEach-Object Value)) { $valueExported=$true }
    }
    $nonDispatchGuardValid=$nonDispatchGuardValid -and $exported
  }
  $expectedValue=@'
function Get-NonDispatchLedgerPath {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$Path)
  dispatch-ledger-reader\Assert-NonDispatchLedgerPath -Path $Path
  return $Path
}
'@
  $valueAst=[Management.Automation.Language.Parser]::ParseInput($expectedValue,[ref]$tokens,[ref]$errors)
  if ($nonDispatchGuardValid -and $valueExported -and $functions.ContainsKey('get-nondispatchledgerpath') -and $functions['get-nondispatchledgerpath'].Count -eq 1) {
    $target=$functions['get-nondispatchledgerpath'][0]
    $nonDispatchValueValid=$target.unit.path -ceq '.orchestrator/dispatch-ledger-reader.psm1' -and
      (TokenShape $target.node.Body) -ceq (TokenShape $valueAst.EndBlock.Statements[0].Body)
  }
  if ($nonDispatchGuardValid) {
    $ownerPath=[IO.Path]::GetFullPath((Join-Path $Root '.orchestrator/dispatch-ledger-reader.psm1'))
    foreach ($unit in $units | Where-Object { -not $_.test -and $_.ast }) {
      foreach ($statement in $unit.ast.EndBlock.Statements) {
        if ($statement -isnot [Management.Automation.Language.PipelineAst] -or $statement.PipelineElements.Count -ne 1) { continue }
        $call=$statement.PipelineElements[0]
        if ($call -isnot [Management.Automation.Language.CommandAst] -or $call.GetCommandName() -ine 'Import-Module' -or $call.CommandElements.Count -lt 2) { continue }
        $options=@($call.CommandElements | Select-Object -Skip 2)
        $validOptions=$true
        $seenOptions=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        for ($i=0;$i -lt $options.Count;$i++) {
          $option=$options[$i]
          if ($option -isnot [Management.Automation.Language.CommandParameterAst] -or $option.Argument -or
              -not $seenOptions.Add($option.ParameterName)) { $validOptions=$false;break }
          if ($option.ParameterName -in @('Global','Force','DisableNameChecking')) { continue }
          # Literal Stop preserves fail-closed imports; other common-parameter
          # values and dynamic/inline arguments are not provenance evidence.
          if ($option.ParameterName -ieq 'ErrorAction' -and $i+1 -lt $options.Count -and
              $options[$i+1] -is [Management.Automation.Language.StringConstantExpressionAst] -and $options[$i+1].Value -ieq 'Stop') {
            $i++;continue
          }
          $validOptions=$false;break
        }
        if (-not $validOptions) { continue }
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
              dataCall=Find-LedgerCensusAst $assignment.Right ([Management.Automation.Language.CommandAst]) | Where-Object { $dataFunctions.Contains((CommandName $_ $unit)) } | Select-Object -First 1
              dataRead=Find-LedgerCensusAst $assignment.Right ([Management.Automation.Language.InvokeMemberExpressionAst]) | Where-Object { $_.Member.Value -match '^Read(All|Lines)' -and $_.Expression -is [Management.Automation.Language.TypeExpressionAst] -and $_.Expression.TypeName.FullName -match '^(System\.)?IO\.File$' } | Select-Object -First 1
              type=Find-LedgerCensusAst $assignment.Right ([Management.Automation.Language.TypeExpressionAst]) | Select-Object -First 1
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
          # Seed every component monotonically. Another component or owner call
          # acquiring facts must never suppress an unseen path variable.
          if ($argument) {
            foreach ($variable in (Find-LedgerCensusAst $argument ([Management.Automation.Language.VariableExpressionAst]))) {
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
    foreach ($alias in (Find-LedgerCensusAst $unit.ast ([Management.Automation.Language.CommandAst]) | Where-Object { $_.GetCommandName() -in @('Set-Alias','New-Alias') })) {
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
    $nodes=if ($unit.ast) { @(Find-LedgerCensusAst $unit.ast @([Management.Automation.Language.InvokeMemberExpressionAst],
      [Management.Automation.Language.CommandAst],[Management.Automation.Language.StringConstantExpressionAst],
      [Management.Automation.Language.ExpandableStringExpressionAst])) } else { @() }
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
          # A mutable receiver's cached type is a hint, never proof of purity.
          # Dynamic members may perform reads regardless of their spelling.
          $opaqueStatic=$node.Static -and
            ($node.Expression -isnot [Management.Automation.Language.TypeExpressionAst] -or
             $node.Member -isnot [Management.Automation.Language.StringConstantExpressionAst])
          $invocationMask=Fact $node $unit
          $constructorCandidate=$node.Static -and $node.Member.Value -ieq 'new' -and
            $type -match '(^|\.)(File|FileStream|StreamReader)(\[|$)'
          if ($opaqueStatic -or ($invocationMask -band 5) -or $constructorCandidate -or
              ($node.Static -and $node.Member.Value -match '(?i)read|open' -and
               $node.Arguments.Count -and -not (NonLedgerPath $node.Arguments[0] $unit))) {
            $unknownFamily=if ($node.Static) {'unknown-static-type'} else {'unknown-instance-type'}
            $rows.Add([pscustomobject]@{path=$unit.path;line=$node.Extent.StartLineNumber;family=$unknownFamily;role='unclassified';authority='indeterminate';owner=$false;test=$unit.test;handled=$false})
          }
          continue
        }
        # A mutable type alias or nonliteral invocation shape cannot inherit
        # native reader/writer authority from an earlier assignment or a guard.
        $unknown=-not $node.Static -or $node.GenericTypeArguments.Count -gt 0 -or $node.NullConditional -or
          $node.Member -isnot [Management.Automation.Language.StringConstantExpressionAst] -or
          $node.Expression -isnot [Management.Automation.Language.TypeExpressionAst]
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
        $owner=$null -ne $factoryOpen -and $node -eq $factoryOpen
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
        $nativeMatches=@([regex]::Matches($text,'\b(?:File\s*\.\s*(?<method>\w+)\s*\(|new\s+(?:global::)?(?:System\s*\.\s*IO\s*\.\s*)?(?<type>FileStream|StreamReader)\s*\()'))
        $streamResult=if ($text -match '\bFileStream\b') { Get-LedgerEmbeddedFileStreams $text } else { $null }
        $streamSites=if ($null -ne $streamResult) { @($streamResult.sites) } else { @() }
        $unclassifiedNative=$text -match '(?i)\busing\s+(?:static\s+|\w+\s*=\s*)(?:System\.)?IO\.(?:File|FileStream|StreamReader)\b'
        foreach ($opaque in [regex]::Matches($text,'(?i)\.\s*\w*(?:read|open)\w*\s*\(')) {
          if (-not @($nativeMatches | Where-Object { $_.Index -le $opaque.Index -and $_.Index+$_.Length -gt $opaque.Index }).Count) { $unclassifiedNative=$true }
        }
        if ($null -ne $streamResult -and -not $streamResult.parsed) { $unclassifiedNative=$true }
        $dispatchContext=$false
        if ($nativeMatches.Count -or $streamSites.Count -or $unclassifiedNative) {
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
        if ($nativeMatches.Count) {
          foreach ($match in $nativeMatches) {
            $method=$match.Groups['method'].Value
            $streamSite=@($streamSites | Where-Object index -EQ $match.Index)
            $embeddedRole=if ($match.Groups['type'].Value -ceq 'FileStream' -and $streamSite.Count -eq 1 -and $streamSite[0].writer) { 'writer' }
              elseif ($method -match '^(Exists|Delete|Move|Copy|Replace|Write.*|Append.*|Create.*|OpenWrite|Get.*|Set.*)$') { 'writer' }
              elseif ($match.Groups['type'].Success -or $method -match '^(Open|OpenRead|OpenText|ReadLines|ReadAllLines|ReadAllText|ReadAllBytes)$') { 'reader' }
              else { 'unclassified' }
            $rows.Add([pscustomobject]@{path=$unit.path;line=$node.Extent.StartLineNumber+($text.Substring(0,$match.Index).Split("`n").Count-1)
              family=('embedded-C#.'+$(if ($match.Groups['method'].Success) {'File.'+$match.Groups['method'].Value} else {$match.Groups['type'].Value}))
              role=$embeddedRole;authority=$(if ($dispatchContext) {'dispatch'} elseif ($embeddedRole -eq 'writer') {'non-ledger'} else {'indeterminate'})
              owner=$false;test=$unit.test;handled=($embeddedRole -eq 'writer')})
          }
        }
        # Syntax also inventories valid constructors with trivia that a lexical
        # fallback cannot recognize. Binding, not spelling, proves write-only.
        foreach ($site in $streamSites) {
          if (@($nativeMatches | Where-Object Index -EQ $site.index).Count) { continue }
          $embeddedRole=if ($site.writer) { 'writer' } else { 'reader' }
          $rows.Add([pscustomobject]@{path=$unit.path;line=$node.Extent.StartLineNumber+($text.Substring(0,$site.index).Split("`n").Count-1)
            family='embedded-C#.FileStream';role=$embeddedRole;authority=$(if ($dispatchContext) {'dispatch'} elseif ($site.writer) {'non-ledger'} else {'indeterminate'})
            owner=$false;test=$unit.test;handled=$site.writer})
        }
        # Unknown embedded readers remain candidates even when their receiver
        # is an alias, using-static import, or an unclassified native family.
        # Do not pretend that recognizing Add-Type proves its payload harmless.
        if ($unclassifiedNative) {
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
      $authority=if ($owner) {'dispatch'} elseif ($role -eq 'reader' -and ((HasPathGuard $node $pathArgument $unit) -or
          ($family -eq 'StreamReader' -and (InlineNonDispatchStreamReader $node $unit)))) {
        if ($mask -eq 2) { 'cost' } else { 'non-ledger' }
      } elseif ($mask -eq 2) {
        if ($role -eq 'reader' -and -not (NonLedgerPath $pathArgument $unit)) { 'indeterminate' } else { 'cost' }
      } elseif ($mask -eq 0) {
        if ($role -eq 'reader' -and -not (NonLedgerPath $pathArgument $unit)) { 'indeterminate' } else { 'non-ledger' }
      } elseif ($mask -band 4) {'indeterminate'}
      elseif ($mask -band 1) {'dispatch'} else {'indeterminate'}
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
    if (-not $unit.ast) {
      # Standalone native sources have no proven I/O/provenance model here.
      # Missing literal ledger text cannot exclude split or runtime paths.
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
