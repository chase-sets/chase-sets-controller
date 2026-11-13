$ErrorActionPreference = 'Stop'
function Assert-True($Condition, [string]$Message) {
  if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}
function Parse-Source([string]$Source) {
  $tokens = $null; $errors = $null
  $ast = [Management.Automation.Language.Parser]::ParseInput($Source, [ref]$tokens, [ref]$errors)
  Assert-True ($errors.Count -eq 0) 'fixture source parses'
  return $ast
}
function Find-Function($Ast, [string]$Name) {
  $found = @($Ast.FindAll({ param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $Name
  }, $true))
  Assert-True ($found.Count -eq 1) "exactly one $Name function"
  return $found[0]
}
$suite = Parse-Source (Get-Content (Join-Path $PSScriptRoot 'heavy-slot.test.ps1') -Raw)
$fixture = Find-Function $suite 'Test-RenameTypeBeforeAcquire'
$statements = @($fixture.Body.EndBlock.Statements)
$loop = @($statements | Where-Object { $_ -is [Management.Automation.Language.ForEachStatementAst] })
Assert-True ($loop.Count -eq 1) 'one candidate/mutant loop'
$prelude = @($statements | Where-Object { $_.Extent.EndOffset -le $loop[0].Extent.StartOffset })
$builder = @($loop[0].Body.Statements | Select-Object -First 2)
Assert-True ($builder[0].Left.Extent.Text -ceq '$copy' -and $builder[1] -is [Management.Automation.Language.IfStatementAst]) 'real fixture builder precedes native execution'
$guardSource = Join-Path $PSScriptRoot 'invoke-heavy-verifier.ps1'
$variants = @{}
& ([scriptblock]::Create(($prelude.Extent.Text -join "`n") + "`nforeach (`$variant in @('candidate','late-load')) {`n" +
  ($builder.Extent.Text -join "`n") + "`n`$variants[`$variant] = `$copy`n}"))
$source = Get-Content $guardSource -Raw
$original = Parse-Source $source
$initializer = (Find-Function $original 'Initialize-OwnerRename').Extent.Text
$queue = (Find-Function $original 'Write-VerifyQueue').Extent.Text
$late = Parse-Source $variants['late-load']
Assert-True ((Find-Function $late 'Initialize-QueueOwnerRename').Extent.Text -ceq $initializer.Replace('OwnerRename','QueueOwnerRename')) 'mutant queue initializer conserves production implementation except its type name'
Assert-True ((Find-Function $late 'Write-VerifyQueue').Extent.Text -ceq $queue.Replace('OwnerRename','QueueOwnerRename')) 'mutant queue publication retains all production checks and atomic publication'
Assert-True ($variants['candidate'] -ceq $source.Replace('public static class OwnerRename {', "public static class OwnerRename {`n#error fix125 injected rename type failure")) 'candidate is only the original compile-failure injection'
Assert-True ((Find-Function $late 'Initialize-OwnerRename').Extent.Text.Contains('#error fix125 injected rename type failure')) 'late owner initializer still fails compilation'
Assert-True (-not $variants['late-load'].Contains('if (-not $isAttachedAdmission) { Initialize-OwnerRename }')) 'mutant moves the early owner compile'
Assert-True ($variants['late-load'].Contains("  Initialize-OwnerRename`n" + '  $temporaryPath = Join-Path $lockPath ("owner.transition."')) 'mutant still compiles at the owner transition after child launch'
Write-Host 'PASS real rename fixture builder: candidate compile injection, isolated byte-conserved queue helper, delayed failing owner transition; native execution NOT_RUN'
