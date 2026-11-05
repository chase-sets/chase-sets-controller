$ErrorActionPreference='Stop'
$checks=0;$red=0;$refusals=0;$mutants=0
function Check([bool]$Condition,[string]$Message) {
  $script:checks++
  if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}
$root=Join-Path ([IO.Path]::GetTempPath()) ('ledger-direct-native-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
try {
  Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'dispatch-ledger-reader.psm1') -Destination $root
  $import="Import-Module (Join-Path `$PSScriptRoot 'dispatch-ledger-reader.psm1') -Global -DisableNameChecking"
  $sources=@(
    @('dispatch-claude-stream-audit.ps1','ReadLines','$Path'),
    @('fleet-exclusive-admission.psm1','ReadAllText','$paths.record'),
    @('issue-6289-bounded-probe-discriminator.ps1','ReadAllText','$candidate'),
    @('lease-contract.psm1','ReadAllBytes','$fullPath'),
    @('lane-admission.ps1','Get-Content','$InputPath'),
    @('ledger-reader-census.psm1','ReadAllText','$full')
  )
  $bytes=[byte[]]@(0xef,0xbb,0xbf,0x61,0x0d,0x0a,0x62,0x0a,0xff)
  $positive=Join-Path $root 'ordinary.json';[IO.File]::WriteAllBytes($positive,$bytes)
  $aliases=@('dispatch-log.jsonl','DISPATCH-LOG.JSONL','./dispatch-log.jsonl',
    'dispatch-log.jsonl.','dispatch-log.jsonl ','dispatch-log.jsonl:guard','dispatch-log.jsonl.:guard')
  foreach ($spec in $sources) {
    $name,$method,$path=$spec
    $errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $name),[ref]$null,[ref]$errors)
    Check ($errors.Count-eq0) "source parses $name"
    $reads=@($ast.FindAll({param($n)
      ($n -is [Management.Automation.Language.InvokeMemberExpressionAst] -and
        $n.Expression.Extent.Text-ceq'[IO.File]' -and $n.Member.Value-ceq$method) -or
      ($method-ceq'Get-Content' -and $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName()-ceq$method)
    },$true))
    Check ($reads.Count-eq1) "complete actual native read inventory $name"
    $read=$reads[0]
    $guard="(dispatch-ledger-reader\Get-NonDispatchLedgerPath -Path $path)"
    $operand=if ($method-ceq'Get-Content') { $read.CommandElements[2] } else { $read.Arguments[0] }
    $guarded=$operand.Extent.Text-ceq$guard
    Check ($guarded-or$operand.Extent.Text-ceq$path) "actual expected operand $name"
    if ($method-ceq'Get-Content') {
      Check ($read.Extent.Text-ceq"Get-Content -LiteralPath $($operand.Extent.Text) -Raw") 'CLI literal path and raw behavior unchanged'
    } elseif ($name-ceq'fleet-exclusive-admission.psm1') {
      Check ($read.Arguments.Count-eq2-and$read.Arguments[1].Extent.Text-ceq'[Text.Encoding]::UTF8') 'UTF8 literal argument retained'
    } else { Check ($read.Arguments.Count-eq1) "single operand $name" }
    # Rebind only the AST path operand. Property receivers and encoding/type
    # literals are not variables to blindly replace in the complete expression.
    $actual=$read.Extent.Text
    $offset=$operand.Extent.StartOffset-$read.Extent.StartOffset
    $native=$actual.Remove($offset,$operand.Extent.Text.Length).Insert($offset,$path)
    $binding=if ($path-ceq'$paths.record') { '$paths=[pscustomobject]@{record=$ProbePath}' } else { "$path=`$ProbePath" }
    $preamble='param([string]$ProbePath)'+"`n"+$import+"`n"+$binding+"`n"
    $probe=Join-Path $root 'probe.ps1'
    # foreach forces lazy ReadLines to perform its native open, including in
    # the guard-removal mutant. The other readers preserve their native output.
    $expression=if ($method-ceq'ReadLines') { "foreach (`$line in $actual) { `$line }" } else { $actual }
    $nativeExpression=if ($method-ceq'ReadLines') { "foreach (`$line in $native) { `$line }" } else { $native }
    [IO.File]::WriteAllText($probe,$preamble+$nativeExpression)
    $expected=@(& $probe $positive)
    [IO.File]::WriteAllText($probe,$preamble+$expression)
    $observed=@(& $probe $positive)
    Check (($observed|ConvertTo-Json -Compress)-ceq($expected|ConvertTo-Json -Compress)) "non-ledger native bytes/text/lines unchanged $name"
    foreach ($case in @('missing.json','ordinary.json')) {
      $target=Join-Path $root $case
      $held=if ($case-ceq'ordinary.json') { [IO.File]::Open($target,'Open','ReadWrite','None') } else { $null }
      try {
        $failures=@(foreach ($body in @($nativeExpression,$expression)) {
          [IO.File]::WriteAllText($probe,$preamble+$body)
          try { & $probe $target|Out-Null; 'NO_FAILURE' }
          catch { $_.Exception.GetBaseException().GetType().FullName+':'+$_.Exception.GetBaseException().Message }
        })
        Check ($failures.Count-eq2-and$failures[0]-cne'NO_FAILURE'-and$failures[0]-ceq$failures[1]) "non-ledger missing/unreadable native failure unchanged $name/$case"
      } finally { if ($held) { $held.Dispose() } }
    }
    [IO.File]::WriteAllText($probe,$preamble+$expression)
    foreach ($alias in $aliases) {
      $target=Join-Path $root $alias;[IO.File]::WriteAllBytes($target,$bytes)
      $held=[IO.File]::Open($target,'Open','ReadWrite','None')
      try {
        $failure='';try { & $probe $target|Out-Null } catch { $failure=$_.Exception.Message }
        if ($failure-match'DISPATCH_LEDGER_OWNER_REQUIRED') { $refusals++ }
        else {
          Check ($failure-match'used by another process|sharing violation|Could not open the.*alternate data stream') "actual native open failure $name/$alias : $failure"
          $red++;Write-Output "RED actual-native $name/$alias"
        }
      } finally { $held.Dispose() }
      Check ([Convert]::ToHexString([IO.File]::ReadAllBytes($target))-ceq[Convert]::ToHexString($bytes)) "rejected alias bytes unchanged $name/$alias"
    }
    if ($guarded) {
      $imports=@($ast.EndBlock.Statements|Where-Object{$_.Extent.Text-ceq$import})
      Check ($imports.Count-eq1-and$imports[0].Extent.EndOffset-lt$read.Extent.StartOffset) "literal global non-forcing import dominates $name"
      Check ($native-cne$actual) "actual operand guard removal changes $name"
      [IO.File]::WriteAllText($probe,$preamble+$nativeExpression)
      foreach ($alias in $aliases) {
        $target=Join-Path $root $alias;$held=[IO.File]::Open($target,'Open','ReadWrite','None')
        try {
          $failure='';try { & $probe $target|Out-Null } catch { $failure=$_.Exception.Message }
          Check ($failure-match'used by another process|sharing violation|Could not open the.*alternate data stream'-and$failure-notmatch'DISPATCH_LEDGER_OWNER_REQUIRED') "guard-removal reaches native open failure $name/$alias : $failure"
          $mutants++
        } finally { $held.Dispose() }
      }
    }
  }
  Write-Output "RESULT direct-native checks=$checks native=6 aliases=7 unsafeRED=$red ownerRefusals=$refusals mutantNativeRED=$mutants positive=6"
  Check ($red-eq0-and$refusals-eq42-and$mutants-eq42) 'all six production operands require owner guards; fixtures are not production proof'
  Write-Output "PASS ledger-reader-direct-native-paths checks=$checks native=6 aliases=7 ownerRefusals=$refusals mutantNativeRED=$mutants positive=6"
} finally {
  $full=[IO.Path]::GetFullPath($root)
  if ((Split-Path -Parent $full).TrimEnd('\','/')-cne([IO.Path]::GetFullPath([IO.Path]::GetTempPath())).TrimEnd('\','/')-or
    (Split-Path -Leaf $full)-cnotlike'ledger-direct-native-*') { throw 'unsafe direct native fixture cleanup' }
  Remove-Item -LiteralPath $full -Recurse -Force
}
