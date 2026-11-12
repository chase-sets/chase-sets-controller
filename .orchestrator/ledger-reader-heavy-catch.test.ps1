$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'ledger-reader-census.psm1') -Force
$checks=0
function Check([bool]$Value,[string]$Message) {
  $script:checks++
  if(-not $Value){throw "ASSERTION FAILED: $Message"}
}
$root=Join-Path ([IO.Path]::GetTempPath()) ('ledger-heavy-catch-'+[guid]::NewGuid().ToString('N'))
try {
  [void][IO.Directory]::CreateDirectory((Join-Path $root '.orchestrator'))
  Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'dispatch-ledger-reader.psm1') -Destination (Join-Path $root '.orchestrator')
  $entry=Join-Path $PSScriptRoot 'invoke-heavy-verifier.ps1'
  $errors=$null
  $ast=[Management.Automation.Language.Parser]::ParseFile($entry,[ref]$null,[ref]$errors)
  Check ($errors.Count -eq 0) 'actual heavy script parses'
  Check (@($ast.FindAll({param($n)$n -is [Management.Automation.Language.TrapStatementAst]},$true)).Count -eq 0) 'no resumable runtime traps'
  $boundary=@($ast.EndBlock.Statements|Where-Object {$_ -is [Management.Automation.Language.TryStatementAst]})
  Check ($boundary.Count -eq 1 -and $boundary[0].CatchClauses.Count -eq 1 -and -not $boundary[0].Finally) 'single outer catch'
  $catch=$boundary[0].CatchClauses[0].Extent.Text
  Check ($boundary[0] -eq $ast.EndBlock.Statements[-1]) 'nothing can resume after the boundary'
  $import='Import-Module (Join-Path $PSScriptRoot ''.orchestrator/dispatch-ledger-reader.psm1'') -Global -DisableNameChecking'
  $helpers=@(foreach($name in @('Close-ReplaySourceStreams','Write-NativeReply','Write-AdmissionResult','Complete-RefusedAttachedAdmission')){
    $f=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$true))
    Check ($f.Count -eq 1) "one actual helper $name"
    $f[0].Extent.Text
  }) -join "`n"
  $read='[IO.File]::ReadAllText((dispatch-ledger-reader\Get-NonDispatchLedgerPath -Path $path))'
  Check (@($ast.FindAll({param($n)$n -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Extent.Text -ceq $read},$true)).Count -gt 0) 'actual guarded native expression'
  $init=@'
$isManifestReplay=$Mode -in @('replay-before','replay-started')
$script:replayExecutionStarted=$Mode -eq 'replay-started'
$isNativeDb=$Mode -eq 'native'
$isAttachedAdmission=$Mode -eq 'attached'
$isControllerSlot=$Mode -eq 'controller'
$isHostVerifier=$Mode -eq 'host'
$isControllerHostHeavyVerifier=$Mode -eq 'controller-host'
$nativeRequest=@{correlation='synthetic-heavy-catch'}
$nativeReplyWritten=$false
$ownedRaw=$null
$admissionRoot=$null
$admissionResultFull=Join-Path $PSScriptRoot 'admission.json'
$AdmissionNonce='synthetic-heavy-catch'
$pin=[IO.File]::OpenRead((Join-Path $PSScriptRoot 'positive.txt'))
$script:replaySources=@{synthetic=@{stream=$pin}}
'@
  $tail=@'
} finally {
  [IO.File]::WriteAllText((Join-Path $PSScriptRoot 'observation.json'),(@{pinReadable=$pin.CanRead}|ConvertTo-Json -Compress))
  $pin.Dispose()
}
'@
  $positive=Join-Path $root 'positive.txt'
  [IO.File]::WriteAllText($positive,"POSITIVE_NATIVE_BYTES`r`n")
  $probe=Join-Path $root 'probe.ps1'
  function Invoke-Probe([string]$Mode,[string]$Path,[switch]$OmitGuard) {
    $expression=if($OmitGuard){$read.Replace('(dispatch-ledger-reader\Get-NonDispatchLedgerPath -Path $path)','$Path')}else{$read}
    $source='param([string]$Mode,[string]$Path)'+"`n"+'$ErrorActionPreference=''Stop'''+"`n"+$import+"`n"+$helpers+"`n"+$init+"`ntry { try {`n"+$expression+"`nWrite-Output 'BODY_RAN'`n} "+$catch+"`n"+$tail
    [IO.File]::WriteAllText($probe,$source,[Text.UTF8Encoding]::new($false))
    $errors=$null
    [void][Management.Automation.Language.Parser]::ParseFile($probe,[ref]$null,[ref]$errors)
    Check ($errors.Count -eq 0) 'native probe parses'
    $start=[Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
    $start.UseShellExecute=$false;$start.CreateNoWindow=$true
    $start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    foreach($a in @('-NoProfile','-NonInteractive','-File',$probe,'-Mode',$Mode,'-Path',$Path)){[void]$start.ArgumentList.Add($a)}
    $p=[Diagnostics.Process]::Start($start)
    try {
      $stdout=$p.StandardOutput.ReadToEndAsync();$stderr=$p.StandardError.ReadToEndAsync()
      if(-not $p.WaitForExit(30000)){throw 'native catch probe timed out'}
      return [pscustomobject]@{code=$p.ExitCode;output=$stdout.Result+"`n"+$stderr.Result;observation=(Get-Content (Join-Path $root 'observation.json') -Raw|ConvertFrom-Json)}
    } finally {
      if(-not $p.HasExited){$p.Kill($true);$p.WaitForExit()}
      $p.Dispose()
    }
  }
  $aliases=@('dispatch-log.jsonl','DISPATCH-LOG.JSONL','./dispatch-log.jsonl','dispatch-log.jsonl.','dispatch-log.jsonl ','dispatch-log.jsonl:catch','dispatch-log.jsonl.:catch')
  $modes=@('gate','host','controller-host','attached','native','replay-before','replay-started')
  foreach($mode in $modes){
    foreach($alias in $aliases){
      $path=Join-Path $root $alias
      [IO.File]::WriteAllText($path,'HELD_DISPATCH_BYTES')
      $held=[IO.File]::Open($path,'Open','ReadWrite','None')
      try {
        $r=Invoke-Probe $mode $path
        $expected=if($mode -in @('gate','replay-started')){1}else{73}
        Check ($r.code -eq $expected -and $r.output -match 'DISPATCH_LEDGER_OWNER_REQUIRED' -and $r.output -notmatch 'BODY_RAN') "native refusal $mode/$alias code=$($r.code)"
        if($mode -like 'replay-*'){Check (-not $r.observation.pinReadable) "actual replay cleanup closes stream $mode/$alias"}
        if($mode -eq 'native'){Check ($r.output -match '"status":"refused"' -and $r.output -match 'synthetic-heavy-catch') 'actual native reply retained'}
        if($mode -eq 'attached'){$a=Get-Content (Join-Path $root 'admission.json') -Raw|ConvertFrom-Json;Check ($a.accepted -eq $false -and $a.message -match 'DISPATCH_LEDGER_OWNER_REQUIRED') 'actual attached refusal record retained'}
      } finally {$held.Dispose()}
      Check ([IO.File]::ReadAllText($path) -ceq 'HELD_DISPATCH_BYTES') 'dispatch bytes unchanged'
    }
    $r=Invoke-Probe $mode $positive
    Check ($r.code -eq 0 -and $r.output -match 'POSITIVE_NATIVE_BYTES' -and $r.output -match 'BODY_RAN') "ordinary native payload $mode"
    $path=Join-Path $root 'dispatch-log.jsonl';$held=[IO.File]::Open($path,'Open','ReadWrite','None')
    try {$r=Invoke-Probe $mode $path -OmitGuard;Check ($r.code -ne 0 -and $r.output -notmatch 'DISPATCH_LEDGER_OWNER_REQUIRED|BODY_RAN') "actual guard removal native RED $mode"}finally{$held.Dispose()}
  }
  Write-Output "PASS heavy catch checks=$checks modes=$($modes.Count) aliases=$($aliases.Count) ownerRefusals=49 nativeGuardRemovalRED=7 replayCleanup=true nativeReply=true attachedReply=true"
} finally {
  $full=[IO.Path]::GetFullPath($root)
  if((Split-Path -Parent $full).TrimEnd('\','/') -cne ([IO.Path]::GetFullPath([IO.Path]::GetTempPath())).TrimEnd('\','/') -or (Split-Path -Leaf $full) -cnotlike 'ledger-heavy-catch-*'){throw 'unsafe catch fixture cleanup'}
  if(Test-Path -LiteralPath $full){Remove-Item -LiteralPath $full -Recurse -Force}
}
