[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'ledger-reader-census.psm1') -Force
$root=Join-Path ([IO.Path]::GetTempPath()) ('ledger-traps-'+[guid]::NewGuid().ToString('N'))
$failures=[Collections.Generic.List[string]]::new()
$checks=0
function Check([bool]$Value,[string]$Message) {
  $script:checks++
  if(-not $Value){throw "ASSERTION FAILED: $Message"}
}
function Invoke-Probe([string]$Source,[string]$Path) {
  $probe=Join-Path $root 'probe.ps1'
  [IO.File]::WriteAllText($probe,$Source,[Text.UTF8Encoding]::new($false))
  $errors=$null
  [void][Management.Automation.Language.Parser]::ParseFile($probe,[ref]$null,[ref]$errors)
  Check ($errors.Count -eq 0) 'native probe parses'
  $start=[Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
  $start.UseShellExecute=$false;$start.CreateNoWindow=$true
  $start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
  foreach($argument in @('-NoProfile','-NonInteractive','-File',$probe,'-Path',$Path)){[void]$start.ArgumentList.Add($argument)}
  $process=[Diagnostics.Process]::Start($start)
  try {
    $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
    if(-not $process.WaitForExit(30000)){throw 'native trap probe timed out'}
    return [pscustomobject]@{code=$process.ExitCode;output=$stdout.Result+"`n"+$stderr.Result}
  } finally {
    if(-not $process.HasExited){$process.Kill($true);$process.WaitForExit()}
    $process.Dispose()
  }
}
try {
  [void][IO.Directory]::CreateDirectory((Join-Path $root '.orchestrator'))
  Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'dispatch-ledger-reader.psm1') -Destination (Join-Path $root '.orchestrator')
  $reader=Join-Path $root 'reader.ps1'
  [IO.File]::WriteAllText($reader,'# synthetic tracked reader')
  & git -C $root init -q
  Check ($LASTEXITCODE -eq 0) 'fixture init'
  & git -C $root add reader.ps1 .orchestrator/dispatch-ledger-reader.psm1
  Check ($LASTEXITCODE -eq 0) 'fixture tracked sources'
  & git -C $root -c user.name=Synthetic -c user.email=synthetic@example.invalid commit -qm traps
  Check ($LASTEXITCODE -eq 0) 'fixture commit'
  $import='Import-Module (Join-Path $PSScriptRoot ''.orchestrator/dispatch-ledger-reader.psm1'') -Force -DisableNameChecking'
  $read='[IO.File]::ReadAllText((dispatch-ledger-reader\Get-NonDispatchLedgerPath -Path $Path))'
  $body='function Read-Synthetic {param($Path);'+$read+'}'
  $heavy=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'invoke-heavy-verifier.ps1'),[ref]$null,[ref]$null)
  $traps=@($heavy.FindAll({param($node)$node -is [Management.Automation.Language.TrapStatementAst]},$true))
  Check ($traps.Count -eq 1) 'actual heavy trap count'
  $actual=$traps[0].Extent.Text
  $cases=[ordered]@{
    actual=@($false,$actual)
    rethrow=@($false,'trap {throw $_.Exception}')
    nonzeroExit=@($false,'trap {if($flag){exit 73};throw $_.Exception}')
    nonzeroBranches=@($false,'trap {if($flag){exit $(if($other){1}else{73})};throw $_.Exception}')
    multipleBranches=@($false,'trap {if($flag){exit $(if($a){1}elseif($b){2}else{73})};throw $_.Exception}')
    quotedControl=@($false,'trap {''continue;exit 0'';throw $_.Exception}')
    dispatchLiteral=@($false,'trap {throw $_.Exception}',$body.Replace('-Path $Path','-Path ''dispatch-log.jsonl'''))
    separateAssertion=@($true,'trap {throw $_.Exception}','function Read-Synthetic {param([string]$Path);dispatch-ledger-reader\Assert-NonDispatchLedgerPath -Path $Path;[IO.File]::ReadAllText($Path)}')
    resume=@($true,'trap {continue}')
    unreachableThrow=@($true,'trap {continue;throw $_.Exception}')
    returnBeforeThrow=@($true,'trap {return;throw $_.Exception}')
    breakBeforeThrow=@($true,'trap {break;throw $_.Exception}')
    nestedContinue=@($true,'trap {if($flag){continue};throw $_.Exception}')
    stringThrow=@($true,'trap {''throw $_.Exception''}')
    commentThrow=@($true,"trap {# throw `$_.Exception`n}")
    conditionalThrow=@($true,'trap {if($flag){throw $_.Exception}}')
    trailingStatement=@($true,'trap {throw $_.Exception;Write-Output never}')
    typedTrap=@($true,'trap [System.Exception] {throw $_.Exception}')
    nestedTrap=@($true,'trap {trap {continue};throw $_.Exception}')
    twoTraps=@($true,'trap {throw $_.Exception};function Other {trap {continue}}')
    localTrap=@($true,'function Other {trap {throw $_.Exception}}')
    zeroExit=@($true,'trap {if($flag){exit 0};throw $_.Exception}')
    unknownExit=@($true,'trap {if($flag){exit $code};throw $_.Exception}')
    zeroBranch=@($true,'trap {if($flag){exit $(if($other){1}else{0})};throw $_.Exception}')
    missingElse=@($true,'trap {if($flag){exit $(if($other){1})};throw $_.Exception}')
    commandExit=@($true,'trap {if($flag){exit (Get-Code)};throw $_.Exception}')
    coercedExit=@($true,'trap {if($flag){exit ''73''};throw $_.Exception}')
    wrongRethrow=@($true,'trap {throw $other.Exception}')
    changedActual=@($true,$actual.Replace('  throw $_.Exception','  continue'))
    removedActual=@($true,$actual.Replace('  throw $_.Exception',''))
    resumedActual=@($true,$actual.Replace('  throw $_.Exception','  continue;throw $_.Exception'))
  }
  foreach($name in $cases.Keys){
    $source=$import+"`n"+$cases[$name][1]+"`n"+$(if($cases[$name].Count -gt 2){$cases[$name][2]}else{$body})
    [IO.File]::WriteAllText($reader,$source,[Text.UTF8Encoding]::new($false))
    $census=Get-LedgerReaderCensus -Root $root
    $bad=$census.violations.Count -gt 0
    Check ($census.scanned -eq 2 -and $census.total -eq 2) "complete census $name"
    if($bad -ne $cases[$name][0]){$failures.Add($name)}
    Write-Output "TRAP case=$name violation=$bad expected=$($cases[$name][0])"
  }
  $dispatch=Join-Path $root 'dispatch-log.jsonl'
  $positive=Join-Path $root 'receipt.json'
  [IO.File]::WriteAllText($dispatch,'DISPATCH_NATIVE_BYTES')
  [IO.File]::WriteAllText($positive,'POSITIVE_NATIVE_BYTES')
  $preamble='param([string]$Path)'+"`n"+$import+"`n"
  $after="`nWrite-Output 'AFTER_NATIVE'"
  $terminal=$preamble+'trap {throw $_.Exception}'+"`n"+$read+$after
  $held=[IO.File]::Open($dispatch,'Open','ReadWrite','None')
  try {
    $refused=Invoke-Probe $terminal $dispatch
    Check ($refused.code -ne 0 -and $refused.output -match 'DISPATCH_LEDGER_OWNER_REQUIRED' -and $refused.output -notmatch 'AFTER_NATIVE') 'terminal guard refuses before exclusively held native read'
    $mutant=Invoke-Probe ($terminal.Replace('(dispatch-ledger-reader\Get-NonDispatchLedgerPath -Path $Path)','$Path')) $dispatch
    Check ($mutant.code -ne 0 -and $mutant.output -notmatch 'DISPATCH_LEDGER_OWNER_REQUIRED') 'guard removal exposes native I/O failure'
    $resumed=Invoke-Probe ($terminal.Replace('throw $_.Exception','continue')) $dispatch
    Check ($resumed.code -eq 0 -and $resumed.output -match 'AFTER_NATIVE') 'resume mutant suppresses refusal; must remain unknown'
  } finally {$held.Dispose()}
  $allowed=Invoke-Probe $terminal $positive
  Check ($allowed.code -eq 0 -and $allowed.output -match 'POSITIVE_NATIVE_BYTES' -and $allowed.output -match 'AFTER_NATIVE') 'positive native payload unchanged'
  $exitSource=$preamble+'$isHostVerifier=$true'+"`n"+$actual+"`n"+$read+$after
  $exited=Invoke-Probe $exitSource $dispatch
  Check ($exited.code -eq 73 -and $exited.output -match 'DISPATCH_LEDGER_OWNER_REQUIRED' -and $exited.output -notmatch 'AFTER_NATIVE') 'actual conditional trap retains nonzero refusal'
  & (Join-Path $PSScriptRoot 'ledger-reader-heavy-paths.test.ps1') -WithTrap
  if($failures.Count){throw "SURVIVED trap classification controls: $($failures -join ',')"}
  Write-Output "PASS typed trap controls=$($cases.Count) nativeChecks=$checks actual28NativePaths=true resumeMutant=RED guardRemoval=RED"
} finally {
  $full=[IO.Path]::GetFullPath($root)
  if((Split-Path -Parent $full).TrimEnd('\','/') -cne ([IO.Path]::GetFullPath([IO.Path]::GetTempPath())).TrimEnd('\','/') -or (Split-Path -Leaf $full) -cnotlike 'ledger-traps-*'){throw 'unsafe trap fixture cleanup'}
  if(Test-Path -LiteralPath $full){Remove-Item -LiteralPath $full -Recurse -Force}
}
