$ErrorActionPreference='Stop'
$script:checks=0
function Check([bool]$Condition,[string]$Message) {
  $script:checks++
  if(-not $Condition){throw "ASSERTION FAILED: $Message"}
}
$root=Join-Path ([IO.Path]::GetTempPath()) ('ledger-battery-paths-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
try {
  $entry=Join-Path $PSScriptRoot 'controller-release-battery.ps1'
  $tokens=$null;$errors=$null
  $ast=[Management.Automation.Language.Parser]::ParseFile($entry,[ref]$tokens,[ref]$errors)
  Check ($errors.Count -eq 0) 'battery parses without executing battery'
  $import="Import-Module (Join-Path `$PSScriptRoot 'dispatch-ledger-reader.psm1') -Force -DisableNameChecking"
  $imports=@($ast.EndBlock.Statements|Where-Object {$_.Extent.Text -ceq $import})
  Check ($imports.Count -eq 1) 'literal unconditional sole-owner import'
  $reads=@($ast.FindAll({param($node)
    ($node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -cin @('Get-Content','Get-FileHash')) -or
    ($node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and
      $node.Expression.Extent.Text -ceq '[IO.File]' -and $node.Member.Value -cin @('ReadAllText','ReadAllBytes','Open','OpenRead'))
  },$true))
  $paths=@('$ownerPath','$ownerPath','$identity.actualPath',
    "'C:/Users/ToddS/.cache/codex-runtimes/codex-primary-runtime/runtime.json'",
    '$absolute','$downloadPath','$identityPath','$resolvedPrior','$priorRawPath',
    '$candidateFile.FullName','$candidateFile.FullName')
  $native=@(
    '[IO.File]::Open($ownerPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))',
    '[IO.File]::Open($ownerPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))',
    'Get-FileHash -LiteralPath $identity.actualPath -Algorithm SHA256 -ErrorAction Stop',
    "[IO.File]::ReadAllText('C:/Users/ToddS/.cache/codex-runtimes/codex-primary-runtime/runtime.json')",
    '[IO.File]::ReadAllText($absolute)', '[IO.File]::ReadAllBytes($downloadPath)',
    'Get-Content -LiteralPath $identityPath -Raw -ErrorAction Stop',
    '[IO.File]::ReadAllBytes($resolvedPrior)', '[IO.File]::ReadAllBytes($priorRawPath)',
    '[IO.File]::OpenRead($candidateFile.FullName)',
    'Get-Content -LiteralPath $candidateFile.FullName -Raw')
  Check ($reads.Count -eq 11) 'ten dynamic native paths plus fixed runtime metadata path'
  Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'dispatch-ledger-reader.psm1') -Destination $root
  $payload='{"synthetic":true,"schemaVersion":1}'
  $positive=Join-Path $root 'receipt.json'
  [IO.File]::WriteAllText($positive,$payload,[Text.UTF8Encoding]::new($false))
  $bytes=[IO.File]::ReadAllBytes($positive)
  $aliases=@('dispatch-log.jsonl','DISPATCH-LOG.JSONL','./dispatch-log.jsonl',
    'dispatch-log.jsonl.','dispatch-log.jsonl ','dispatch-log.jsonl:battery','dispatch-log.jsonl.:battery')
  $probe=Join-Path $root 'probe.ps1'
  $bindings=@'
$ownerPath=$absolute=$downloadPath=$identityPath=$resolvedPrior=$priorRawPath=$ProbePath
$identity=[pscustomobject]@{actualPath=$ProbePath}
$candidateFile=[pscustomobject]@{FullName=$ProbePath}
'@
  for($index=0;$index -lt $reads.Count;$index++) {
    $read=$reads[$index]
    $guard="(dispatch-ledger-reader\Get-NonDispatchLedgerPath -Path $($paths[$index]))"
    Check ($read.Extent.Text.Replace($guard,$paths[$index]) -ceq $native[$index]) "native API, overload, switches and original expression preserved $index"
    Check ($read.Extent.Text.Contains($guard,[StringComparison]::Ordinal)) "original expression guarded $index"
    Check ($imports[0].Extent.EndOffset -lt $read.Extent.StartOffset) "owner imported before read $index"
    # The fixed metadata literal is verified structurally, never redirected to a
    # fixture or used to write into the real runtime cache. All ten dynamic
    # candidates execute their exact production native expression below.
    if($index -eq 3){continue}
    [IO.File]::WriteAllText($probe,('param([string]$ProbePath)'+"`n"+$import+"`n"+$bindings+"`n"+$read.Extent.Text))
    $result=& $probe $positive
    try {
      switch($index) {
        {$_ -in @(0,1,9)} {
          Check ($result.CanRead -and -not $result.CanWrite) "read-only stream $index"
          $reader=[IO.StreamReader]::new($result,[Text.Encoding]::UTF8,$true,1024,$true)
          try {Check ($reader.ReadToEnd() -ceq $payload) "stream payload $index"} finally {$reader.Dispose()}
          if($index -in @(0,1)) {
            $other=[IO.File]::Open($positive,'Open','ReadWrite',([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
            $other.Dispose()
            Check $true "owner stream retains write/delete sharing $index"
          } else {
            $blocked=$false
            try {$other=[IO.File]::Open($positive,'Open','Write','ReadWrite');$other.Dispose()}catch{$blocked=$true}
            Check $blocked 'timing prefix retains OpenRead write exclusion'
          }
        }
        2 {Check ($result.Hash -ceq (Get-FileHash -LiteralPath $positive -Algorithm SHA256).Hash) 'actual native host hash'}
        {$_ -in @(5,7,8)} {Check ([Convert]::ToBase64String([byte[]]$result) -ceq [Convert]::ToBase64String($bytes)) "exact native bytes $index"}
        default {Check ($result -ceq $payload) "native text $index"}
      }
    } finally {if($result -is [IDisposable]){$result.Dispose()}}
    foreach($alias in $aliases) {
      $target=Join-Path $root $alias
      # First absent, then valid bytes held exclusively: neither native missing
      # file errors nor native sharing failures may replace the owner refusal.
      $missing=Join-Path $root ('absent-'+$index)
      [void][IO.Directory]::CreateDirectory($missing)
      $failure=''
      try {& $probe (Join-Path $missing $alias)|Out-Null}catch{$failure=$_.Exception.Message}
      Check ($failure -like '*DISPATCH_LEDGER_OWNER_REQUIRED*') "missing alias refuses pre-I/O $index/$alias : $failure"
      [IO.File]::WriteAllBytes($target,$bytes)
      $held=[IO.File]::Open($target,'Open','ReadWrite','None')
      try {
        $failure=''
        try {& $probe $target|Out-Null}catch{$failure=$_.Exception.Message}
        Check ($failure -like '*DISPATCH_LEDGER_OWNER_REQUIRED*') "valid exclusive alias refuses pre-I/O $index/$alias : $failure"
      } finally {$held.Dispose()}
      Check ([Convert]::ToBase64String([IO.File]::ReadAllBytes($target)) -ceq [Convert]::ToBase64String($bytes)) "alias untouched $index/$alias"
    }
  }

  # Load full production functions, not the top-level battery, admission or
  # verifier. Real fleet parsing and reference fallback exercise the guards
  # within the original retry/catch/stream lifetimes.
  $definitions=[Collections.Generic.List[string]]::new()
  $definitions.Add($import)
  foreach($name in @('Test-BatteryProcessIdentityLive','Get-BatteryFleetLoad','Get-BatteryReferenceText',
      'Get-BatteryReferenceKey','New-BatteryFleetSampler','Add-BatteryFleetObservation',
      'Invoke-BatteryFleetSamplerLoop','Start-BatteryFleetSampler','Complete-BatteryFleetSampler','Stop-BatteryFleetSamplerHost',
      'Test-SameBatteryPath','Assert-BatteryAdmission','Stop-Battery')) {
    $definition=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name},$true))
    Check ($definition.Count -eq 1) "one complete production function $name"
    $definitions.Add($definition[0].Extent.Text)
  }
  $library=Join-Path $root 'library.ps1'
  [IO.File]::WriteAllText($library,($definitions -join "`n"))
  . $library
  $controller=Join-Path $root 'checkout'
  $runtime=Join-Path $root '.orchestrator'
  $lock=Join-Path $runtime 'verify-lock.d';[void][IO.Directory]::CreateDirectory($lock)
  [void][IO.Directory]::CreateDirectory($controller)
  $ownerPath=Join-Path $lock 'owner.json'
  $self=Get-Process -Id $PID
  $owner=@{pid=$PID;processStartUtc=$self.StartTime.ToUniversalTime().ToString('o');lane='fixture';gate='fixture';lockId='fixture'}
  [IO.File]::WriteAllText($ownerPath,($owner|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($true))
  Check ((Get-BatteryFleetLoad -Holder).lane -ceq 'fixture') 'full fleet function reads BOM owner and validates process'
  [IO.File]::WriteAllText($ownerPath,'invalid')
  Check ((Get-BatteryFleetLoad) -ceq 'none') 'full fleet function retains malformed fallback'
  [IO.File]::WriteAllText($ownerPath,($owner|ConvertTo-Json -Compress))
  $fleetSampling=@{host=$null}
  $sampler=New-BatteryFleetSampler 'fixture' (Get-BatteryFleetLoad -Holder)
  try {
    Start-BatteryFleetSampler $sampler
    $deadline=[DateTime]::UtcNow.AddSeconds(5)
    while($sampler.inFlight -lt 1 -and [DateTime]::UtcNow -lt $deadline){Start-Sleep -Milliseconds 25}
    $holder=Complete-BatteryFleetSampler $sampler
    Check ($holder.holders.Count -eq 1 -and $holder.holders[0].moments.Contains('during')) 'full sampler fresh runspace imports owner and observes real owner'
    Check ($fleetSampling.host.shell.Streams.Error.Count -eq 0) 'fresh sampler runspace has no import errors'
    Stop-BatteryFleetSamplerHost
  } finally {Stop-BatteryFleetSamplerHost}
  & {
    # Synthetic admission only. No heavy slot is acquired and no battery is
    # invoked; the branch response is the only external authority substituted.
    function git {'fixture-branch'}
    $oldToken=$env:CHASE_SETS_HEAVY_SLOT_ID
    try {
      $env:CHASE_SETS_HEAVY_SLOT_ID='a'*32
      $ExpectedControllerHead='b'*40
      $admissionLock=Join-Path $runtime 'controller-verify-lock.d'
      [void][IO.Directory]::CreateDirectory($admissionLock)
      $admissionOwner=@{schemaVersion=4;lockId=$env:CHASE_SETS_HEAVY_SLOT_ID;gate='script-battery';state='started'
        identityMode='branch';worktree=$controller;head=$ExpectedControllerHead;branch='fixture-branch'
        pid=$PID;childPid=$PID;processStartUtc=$self.StartTime.ToUniversalTime().ToString('o')
        childProcessStartUtc=$self.StartTime.ToUniversalTime().ToString('o')}
      [IO.File]::WriteAllText((Join-Path $admissionLock 'owner.json'),($admissionOwner|ConvertTo-Json -Compress))
      Assert-BatteryAdmission
      Check $true 'full admission body reads valid local owner with original process/branch predicates'
    } finally {$env:CHASE_SETS_HEAVY_SLOT_ID=$oldToken}
  }
  $reference=Join-Path $controller 'reference.txt';[IO.File]::WriteAllText($reference,$payload)
  Check ((Get-BatteryReferenceText 'reference.txt') -ceq $payload) 'full reference fallback reads real non-dispatch content'
  foreach($alias in $aliases) {
    $target=Join-Path $controller $alias;[IO.File]::WriteAllText($target,$payload)
    $held=[IO.File]::Open($target,'Open','ReadWrite','None')
    try {
      $failure='';try {Get-BatteryReferenceText $alias|Out-Null}catch{$failure=$_.Exception.Message}
      Check ($failure -like '*DISPATCH_LEDGER_OWNER_REQUIRED*') "full reference function pre-I/O refusal $alias : $failure"
    } finally {$held.Dispose()}
  }
  $streams=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $node.Expression.Extent.Text -ceq '[IO.StreamReader]'},$true))
  Check ($streams.Count -eq 2 -and @($streams|Where-Object {$_.Arguments[0].Extent.Text -cne '(dispatch-ledger-reader\Get-NonDispatchLedgerStream -Stream $stream)' -or $_.Arguments.Count -ne 3 -or $_.Arguments[1].Extent.Text -cne '[Text.Encoding]::UTF8' -or $_.Arguments[2].Extent.Text -cne '$true'}).Count -eq 0) 'both decoder encodings and BOM roles retained with per-use stream guards'
  $nativeSource=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.StringConstantExpressionAst] -and $node.Value.Contains('using (var stream = new FileStream(parent, FileAccess.Write))')},$true))
  Check ($nativeSource.Count -eq 1) 'embedded C# exact writer proof remains present, not a reader exemption'
  Write-Output "PASS ledger-reader-battery-paths checks=$script:checks dynamicNative=10 fixedNative=1 guardedStreamHandle=2 embeddedWriter=1"
} finally {
  $full=[IO.Path]::GetFullPath($root)
  if((Split-Path -Parent $full).TrimEnd('\','/') -cne ([IO.Path]::GetFullPath([IO.Path]::GetTempPath())).TrimEnd('\','/') -or
    (Split-Path -Leaf $full) -cnotlike 'ledger-battery-paths-*'){throw 'unsafe battery fixture cleanup'}
  Remove-Item -LiteralPath $full -Recurse -Force
}
