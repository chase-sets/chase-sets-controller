$ErrorActionPreference='Stop'
$script:checks=0
function Check([bool]$Condition,[string]$Message) {
  $script:checks++
  if(-not $Condition){throw "ASSERTION FAILED: $Message"}
}
$root=Join-Path ([IO.Path]::GetTempPath()) ('ledger-evidence-paths-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
$module=$null
try {
  $entry=Join-Path $PSScriptRoot 'landed-integration-evidence.psm1'
  $tokens=$null;$errors=$null
  $ast=[Management.Automation.Language.Parser]::ParseFile($entry,[ref]$tokens,[ref]$errors)
  Check ($errors.Count -eq 0) 'evidence module parses'
  $import="Import-Module (Join-Path `$PSScriptRoot 'dispatch-ledger-reader.psm1') -Global -Force -DisableNameChecking"
  $imports=@($ast.EndBlock.Statements|Where-Object {$_.Extent.Text -ceq $import})
  Check ($imports.Count -eq 1) 'literal unconditional owner import'
  $reads=@($ast.FindAll({param($node)
    $node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and
    $node.Expression.Extent.Text -ceq '[IO.File]' -and
    ($node.Member.Value -cin @('ReadAllText','ReadAllBytes') -or
      ($node.Member.Value -ceq 'Open' -and $node.Arguments[2].Extent.Text -ceq '[IO.FileAccess]::Read'))
  },$true))
  $paths=@('$Path','$Path','$path','$path','$path','$p','$reference.path',
    '$file.FullName','$path','$path',
    '$(if ($null -ne $gitPaths) { $gitPaths[''index''] } else { Get-RebaseGitPath $Worktree ''index'' })',
    '$checkpointPath','$w.originalPromptPath','$ackPath','$watchdogPath',
    '$w.originalPromptPath','$w.partialReportPath','$ownerPath','$path',
    '$w.originalPromptPath','$w.originalPromptPath','$checkpointPath',
    '$watchdogPath','$w.originalPromptPath','$w.partialReportPath',
    '(Join-Path $Runtime "dispatch-start-$request.json")','$finish.path',
    '$PromptPath','$grant.decisionPath','$capture.path')
  Check ($reads.Count -eq 30 -and $reads.Count -eq $paths.Count) 'thirty native non-dispatch inputs'
  Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'dispatch-ledger-reader.psm1') -Destination $root
  $payload='{"synthetic":true,"items":[1,2]}'
  $positive=Join-Path $root 'authority.json'
  [IO.File]::WriteAllText($positive,$payload,[Text.UTF8Encoding]::new($false))
  # Module-qualified commands need the owner in the global module table. A
  # warmed parent scope would hide a nested-only import failure.
  $cold=Join-Path $root 'cold.ps1'
  [IO.File]::WriteAllText($cold,@'
param($Entry,$Positive)
$ErrorActionPreference='Stop'
Import-Module $Entry -Force -DisableNameChecking
if(-not (Read-RebaseJson $Positive).synthetic){throw 'cold JSON read failed'}
Import-Module $Entry -Force -DisableNameChecking
if(-not (Read-RebaseJson $Positive).synthetic){throw 'reloaded JSON read failed'}
'@)
  function Invoke-Cold([string]$ModulePath) {
    $psi=[Diagnostics.ProcessStartInfo]::new('pwsh')
    $psi.UseShellExecute=$false;$psi.CreateNoWindow=$true
    $psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
    foreach($argument in @('-NoProfile','-NonInteractive','-File',$cold,$ModulePath,$positive)){[void]$psi.ArgumentList.Add($argument)}
    $child=[Diagnostics.Process]::Start($psi)
    try {
      $stdout=$child.StandardOutput.ReadToEndAsync();$stderr=$child.StandardError.ReadToEndAsync()
      if(-not $child.WaitForExit(30000)){$child.Kill($true);$child.WaitForExit();throw 'cold module probe timeout'}
      [pscustomobject]@{code=$child.ExitCode;text=($stdout.GetAwaiter().GetResult()+$stderr.GetAwaiter().GetResult())}
    } finally {$child.Dispose()}
  }
  $fresh=Invoke-Cold $entry
  Check ($fresh.code -eq 0) "fresh native module and force reload: $($fresh.text)"
  Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'dispatch-ownership.ps1') -Destination $root
  $mutant=Join-Path $root 'landed-integration-evidence.psm1'
  [IO.File]::WriteAllText($mutant,$ast.Extent.Text.Replace($import,$import.Replace(' -Global','')))
  $missingGlobal=Invoke-Cold $mutant
  Check ($missingGlobal.code -ne 0 -and $missingGlobal.text -like '*dispatch-ledger-reader*could not be loaded*') 'nested-only import removal control refuses in cold child'
  $aliases=@('dispatch-log.jsonl','DISPATCH-LOG.JSONL','./dispatch-log.jsonl',
    'dispatch-log.jsonl.','dispatch-log.jsonl ','dispatch-log.jsonl:proof','dispatch-log.jsonl.:proof')
  $probe=Join-Path $root 'probe.ps1'
  $bindings=@'
$Path=$p=$checkpointPath=$ackPath=$watchdogPath=$ownerPath=$PromptPath=$ProbePath
$reference=$finish=$capture=[pscustomobject]@{path=$ProbePath}
$file=[pscustomobject]@{FullName=$ProbePath}
$w=[pscustomobject]@{originalPromptPath=$ProbePath;partialReportPath=$ProbePath}
$grant=[pscustomobject]@{decisionPath=$ProbePath}
$gitPaths=@{index=$ProbePath}
$Runtime=Split-Path -Parent $ProbePath; $request='synthetic'
function Join-Path { param($Path,$ChildPath) $ProbePath }
'@
  for($index=0;$index -lt $reads.Count;$index++) {
    $read=$reads[$index]
    Check ($read.Arguments[0].Extent.Text -ceq "(dispatch-ledger-reader\Get-NonDispatchLedgerPath -Path $($paths[$index]))") "original input frozen once index=$index"
    Check ($imports[0].Extent.EndOffset -lt $read.Extent.StartOffset) "owner precedes read index=$index"
    # Run the actual production expression, including native overload/access/share.
    # Bind its original inputs without replacing the path guard or native reader.
    [IO.File]::WriteAllText($probe,('param([string]$ProbePath)'+"`n"+$import+"`n"+$bindings+"`n"+$read.Extent.Text))
    if($read.Member.Value -ceq 'Open') {
      $stream=& $probe $positive
      try {
        Check ($stream.CanRead -and -not $stream.CanWrite) 'fleet owner remains read-only'
        $concurrent=[IO.File]::Open($positive,'Open','ReadWrite',([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        $concurrent.Dispose()
        $reader=[IO.StreamReader]::new($stream,[Text.Encoding]::UTF8,$true)
        try {Check ($reader.ReadToEnd() -ceq $payload) 'fleet stream preserves bytes'} finally {$reader.Dispose()}
      } finally {$stream.Dispose()}
    } elseif($read.Member.Value -ceq 'ReadAllBytes') {
      $actual=[byte[]]@(& $probe $positive)
      Check ([Convert]::ToBase64String($actual) -ceq [Convert]::ToBase64String([IO.File]::ReadAllBytes($positive))) "native exact bytes index=$index"
    } else { Check ((& $probe $positive) -ceq $payload) "native text index=$index" }
    foreach($alias in $aliases) {
      # Nonexistent paths distinguish the owner refusal from native I/O errors.
      $failure=''
      try {& $probe ([IO.Path]::Combine($root,$alias))|Out-Null} catch {$failure=$_.Exception.Message}
      Check ($failure -like '*DISPATCH_LEDGER_OWNER_REQUIRED*') "pre-I/O refusal index=$index alias=$alias : $failure"
    }
  }
  $streamReaders=@($ast.FindAll({param($node)
    $node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and
    $node.Expression.Extent.Text -ceq '[IO.StreamReader]'
  },$true))
  Check ($streamReaders.Count -eq 1 -and $streamReaders[0].Extent.Text -ceq '[IO.StreamReader]::new((dispatch-ledger-reader\Get-NonDispatchLedgerStream -Stream $stream), [Text.Encoding]::UTF8, $true)') 'exact native stream guard; encoding and BOM constructor arguments unchanged'
  $history=@($ast.FindAll({param($node)
    $node -is [Management.Automation.Language.CommandAst] -and
    $node.GetCommandName() -ceq 'Read-RebaseJsonLines' -and
    @($node.CommandElements|Where-Object {$_.Extent.Text -ceq '-DispatchHistory'}).Count -gt 0
  },$true))
  Check ($history.Count -eq 2) 'both real dispatch histories remain on owner snapshot path'
  $module=Import-Module $entry -Force -DisableNameChecking -PassThru
  Check ((Read-RebaseJson $positive).synthetic -eq $true) 'real JSON helper positive'
  [IO.File]::WriteAllText($positive,'{"duplicate":1,"duplicate":2}')
  $failure='';try {Read-RebaseJson $positive|Out-Null}catch{$failure=$_.Exception.Message}
  Check ($failure -like '*duplicate key*') 'real JSON duplicate refusal preserved'
  [IO.File]::WriteAllBytes($positive,[byte[]]@(0xff))
  $failure='';try {Read-RebaseJson $positive|Out-Null}catch{$failure=$_.Exception.Message}
  Check (-not [string]::IsNullOrWhiteSpace($failure)) 'real strict UTF8 refusal preserved'
  $record=Join-Path $root 'immutable.json'
  Write-RebaseRecord $record @{a=1}
  Write-RebaseRecord $record @{a=1}
  $failure='';try {Write-RebaseRecord $record @{a=2}}catch{$failure=$_.Exception.Message}
  Check ($failure -ceq 'OWED_REBASE_PROOF_AMBIGUOUS: immutable record') 'immutable readback still refuses changed bytes'
  $canonical=Join-Path $root 'dispatch-log.jsonl'
  [IO.File]::WriteAllText($canonical,'{"synthetic":true}')
  $held=[IO.File]::Open($canonical,'Open','ReadWrite','None')
  try {
    foreach($operation in @({Read-RebaseJson $canonical},{Write-RebaseRecord $canonical @{synthetic=$true}})) {
      $failure='';try {& $operation|Out-Null}catch{$failure=$_.Exception.Message}
      Check ($failure -like '*DISPATCH_LEDGER_OWNER_REQUIRED*') 'real helper refuses before canonical native open'
    }
  } finally {$held.Dispose()}
  Check ([IO.File]::ReadAllText($canonical) -ceq '{"synthetic":true}') 'canonical payload unchanged'
  $runtime=Join-Path $root '.orchestrator/verify-lock.d'
  [void][IO.Directory]::CreateDirectory($runtime)
  $owner=Join-Path $runtime 'owner.json'
  [IO.File]::WriteAllText($owner,'invalid')
  Check ((Get-FleetLoadObservation $root).reason -ceq 'unparseable') 'real fleet reader remains fail-closed for invalid JSON'
  [IO.File]::WriteAllText($owner,'{"pid":0}',[Text.UTF8Encoding]::new($true))
  Check ((Get-FleetLoadObservation $root).reason -ceq 'stale') 'real fleet reader preserves BOM detection'
  Write-Output "PASS evidence non-dispatch boundaries checks=$script:checks native=30 unresolvedStreamHandle=1"
} finally {
  if($module){Remove-Module $module -Force}
  $full=[IO.Path]::GetFullPath($root)
  if((Split-Path -Parent $full).TrimEnd('\','/') -cne ([IO.Path]::GetFullPath([IO.Path]::GetTempPath())).TrimEnd('\','/') -or
    (Split-Path -Leaf $full) -cnotlike 'ledger-evidence-paths-*'){throw 'unsafe evidence fixture cleanup'}
  Remove-Item -LiteralPath $full -Recurse -Force
}
