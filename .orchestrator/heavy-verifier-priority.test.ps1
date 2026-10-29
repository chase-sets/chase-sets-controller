[CmdletBinding()]
param([ValidateSet('structure','admission')][string]$Part='')
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'suite-parts.ps1')
Assert-SuiteSelection $Part @('structure','admission') $PSBoundParameters @()
$runStructure=Test-SuitePart $Part 'structure'
$runAdmission=Test-SuitePart $Part 'admission'
function Assert-True([bool]$Value,[string]$Name) { if(-not $Value){throw "ASSERTION FAILED: $Name"} }
function Write-Text([string]$Path,[string]$Value) { [IO.File]::WriteAllText($Path,$Value,[Text.UTF8Encoding]::new($false)) }

$guardPath=Join-Path $PSScriptRoot 'invoke-heavy-verifier.ps1'
$guard=[IO.File]::ReadAllText($guardPath)
$guardTokens=$null;$guardErrors=$null
$guardAst=[Management.Automation.Language.Parser]::ParseInput($guard,[ref]$guardTokens,[ref]$guardErrors)
Assert-True ($guardErrors.Count -eq 0) 'heavy-verifier priority source parses'
$eligibilityCalls=@($guardAst.FindAll({param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ceq 'Assert-HeavyCallerEligibility'},$true))
Assert-True ($eligibilityCalls.Count -eq 6) 'every production eligibility call is present exactly once'
foreach($call in $eligibilityCalls){
  $scoped=$false
  for($parent=$call.Parent;$null -ne $parent;$parent=$parent.Parent){
    if($parent -is [Management.Automation.Language.ScriptBlockExpressionAst] -and
       $parent.Parent -is [Management.Automation.Language.CommandAst] -and
       $parent.Parent.GetCommandName() -ceq 'Invoke-HeavyAdmissionCensus'){$scoped=$true;break}
  }
  Assert-True $scoped "eligibility call at line $($call.Extent.StartLineNumber) is outside the raised admission scope"
}

if($runAdmission){
  $fixtureRoot=Join-Path ([IO.Path]::GetTempPath()) ('heavy-verifier-priority-admission-'+[guid]::NewGuid().ToString('N'))
  $fixtureContainer=Join-Path $fixtureRoot 'container'
  $fixtureWorktree=Join-Path $fixtureContainer 'worktree'
  $fixtureRuntime=Join-Path $fixtureContainer '.orchestrator'
  $fixtureChild=Join-Path $fixtureRoot 'child.ps1'
  $fixtureRunner=Join-Path $fixtureRoot 'runner.ps1'
  $fixtureGuard=Join-Path $fixtureRoot 'invoke-heavy-verifier.ps1'
  New-Item -ItemType Directory -Path $fixtureRuntime,$fixtureWorktree -Force | Out-Null
  try {
    & git init --quiet --initial-branch=fixture $fixtureWorktree
    & git -C $fixtureWorktree config user.name Fixture
    & git -C $fixtureWorktree config user.email fixture@example.invalid
    Write-Text (Join-Path $fixtureWorktree 'seed.txt') 'seed'
    & git -C $fixtureWorktree add --all
    & git -C $fixtureWorktree commit --quiet -m seed
    $fixtureHead=(& git -C $fixtureWorktree rev-parse HEAD).Trim()
    Write-Text $fixtureChild @'
param([string]$OutputPath)
$process=Get-Process -Id $PID
[IO.File]::WriteAllText($OutputPath,([ordered]@{
  priority=[string]$process.PriorityClass
  pid=$process.Id
}|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
'@
    Write-Text $fixtureRunner @'
param([string]$Guard,[string]$Container,[string]$Worktree,[string]$Head,[string]$Child,[string]$ChildOutput,[string]$Mode,[switch]$Cancel)
$ErrorActionPreference='Stop'
$process=[Diagnostics.Process]::GetCurrentProcess()
$process.PriorityClass=[Diagnostics.ProcessPriorityClass]::$Mode
$inheritedSlotId=$env:CHASE_SETS_HEAVY_SLOT_ID
$inheritedSlotTransport=$env:CHASE_SETS_HEAVY_SLOT_TRANSPORT
Remove-Item Env:CHASE_SETS_HEAVY_SLOT_ID -ErrorAction SilentlyContinue
Remove-Item Env:CHASE_SETS_HEAVY_SLOT_TRANSPORT -ErrorAction SilentlyContinue
if([string]::IsNullOrWhiteSpace($inheritedSlotId) -or [string]::IsNullOrWhiteSpace($inheritedSlotTransport) -or
   $env:CHASE_SETS_HEAVY_SLOT_ID -or $env:CHASE_SETS_HEAVY_SLOT_TRANSPORT){
  throw 'ASSERTION FAILED: isolated admission fixture did not clear inherited heavy-slot environment'
}
$parameters=@{
  Gate='verify:static';Worktree=$Worktree;Lane='priority-fixture';Branch='fixture';ClaimedHead=$Head
  ContainerRoot=$Container;CommandPath=(Join-Path $PSHOME 'pwsh.exe')
  CommandArgumentList=@('-NoProfile','-NonInteractive','-File',$Child,$ChildOutput)
}
if($Cancel){$parameters.TestCancelAfterAcquisition=$true}
Write-Output 'PASS heavy-verifier-priority battery-context=AdmissionOwned-cleared'
& $Guard @parameters
exit $LASTEXITCODE
'@
    function Invoke-AdmissionFixture([string]$Guard,[string]$Mode,[switch]$Cancel){
      $childOutput=Join-Path $fixtureRoot ("child-$Mode-$(if($Cancel){'cancel'}else{'success'}).json")
      $fixtureTimeoutMilliseconds=300000
      $start=[Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'pwsh.exe'))
      $start.UseShellExecute=$false;$start.CreateNoWindow=$true
      $start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
      foreach($argument in @('-NoProfile','-NonInteractive','-File',$fixtureRunner,'-Guard',$Guard,'-Container',$fixtureContainer,
          '-Worktree',$fixtureWorktree,'-Head',$fixtureHead,'-Child',$fixtureChild,'-ChildOutput',$childOutput,'-Mode',$Mode)){
        [void]$start.ArgumentList.Add($argument)
      }
      if($Cancel){[void]$start.ArgumentList.Add('-Cancel')}
      # Simulate the admitted ControllerBattery environment. The isolated
      # runner must clear both descriptors before invoking a fresh verifier.
      $start.Environment['CHASE_SETS_HEAVY_SLOT_ID']='0123456789abcdef0123456789abcdef'
      $start.Environment['CHASE_SETS_HEAVY_SLOT_TRANSPORT']='fixture-inherited-transport'
      $process=[Diagnostics.Process]::Start($start)
      if(-not $process.WaitForExit($fixtureTimeoutMilliseconds)){
        try{$process.Kill($true)}catch{}
        [void]$process.WaitForExit(10000)
        throw "ASSERTION FAILED: real admission fixture timed out mode=$Mode cancel=$Cancel"
      }
      return [pscustomobject]@{exitCode=$process.ExitCode;output=(($process.StandardOutput.ReadToEnd()+"`n"+$process.StandardError.ReadToEnd()).Trim());childOutput=$childOutput}
    }
    $admissionModes=if($env:HV_PRIORITY_ADMISSION_MODES){@($env:HV_PRIORITY_ADMISSION_MODES -split ',')}else{@('BelowNormal','Idle','Normal')}
    foreach($mode in $admissionModes){
      $result=Invoke-AdmissionFixture $guardPath $mode
      Assert-True ($result.exitCode -eq 0) "real admission fixture succeeds mode=$mode output=$($result.output)"
      Assert-True ($result.output -match 'battery-context=AdmissionOwned-cleared') "real admission fixture clears battery context mode=$mode output=$($result.output)"
      Assert-True (Test-Path -LiteralPath $result.childOutput) "real admission fixture launched child mode=$mode"
      $childRecord=Get-Content -LiteralPath $result.childOutput -Raw | ConvertFrom-Json
      Assert-True ([string]$childRecord.priority -ceq $mode) "child inherits restored priority mode=$mode"
      Assert-True (-not (Test-Path -LiteralPath (Join-Path $fixtureRuntime 'verify-lock.d'))) "real admission fixture reclaims lock mode=$mode"
      Write-Output "PASS heavy-verifier-priority real-admission mode=$mode child=$($childRecord.priority)"
    }
    $mutant=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'invoke-heavy-verifier.ps1')).Replace("`r`n","`n")
    $exitCounter='$script:heavyAdmissionPriorityDepth = 0'
    Assert-True (([regex]::Matches($mutant,[regex]::Escape($exitCounter))).Count -eq 1) 'restore-failure fixture counter anchor is unique'
    $mutant=$mutant.Replace($exitCounter,"$exitCounter`n`$script:heavyAdmissionPriorityExitCount = 0")
    $exitAnchor='function Exit-HeavyAdmissionPriority {'
    Assert-True (([regex]::Matches($mutant,[regex]::Escape($exitAnchor))).Count -eq 1) 'restore-failure fixture exit anchor is unique'
    $mutant=$mutant.Replace($exitAnchor,"$exitAnchor`n  `$script:heavyAdmissionPriorityExitCount++")
    $restoreAnchor="try {`n      `$process.PriorityClass = `$script:heavyAdmissionPriorityClass"
    Assert-True (([regex]::Matches($mutant,[regex]::Escape($restoreAnchor))).Count -eq 1) 'restore-failure fixture setter anchor is unique'
    $restoreReplacement="try {`n      if (`$env:HV_PRIORITY_RESTORE_FAIL -ceq '1' -and `$script:heavyAdmissionPriorityExitCount -eq 3) { throw [UnauthorizedAccessException]::new('synthetic restore denied') }`n      `$process.PriorityClass = `$script:heavyAdmissionPriorityClass"
    $mutant=$mutant.Replace($restoreAnchor,$restoreReplacement)
    $actionAnchor='    Assert-HeavyAdmissionAfterLock $queueLockCreated'
    Assert-True (([regex]::Matches($mutant,[regex]::Escape($actionAnchor))).Count -eq 1) 'action-failure fixture admission anchor is unique'
    $mutant=$mutant.Replace($actionAnchor,"$actionAnchor`n    if (`$env:HV_PRIORITY_ACTION_FAIL -ceq '1') { throw [OperationCanceledException]::new('synthetic action failure') }")
    Write-Text $fixtureGuard $mutant
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'dispatch-ownership.ps1') -Destination (Join-Path $fixtureRoot 'dispatch-ownership.ps1')
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'heavy-nested-owner.cs') -Destination (Join-Path $fixtureRoot 'heavy-nested-owner.cs')
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'heavy-nested-client.cjs') -Destination (Join-Path $fixtureRoot 'heavy-nested-client.cjs')
    foreach($cancel in @($false,$true)){
      $env:HV_PRIORITY_RESTORE_FAIL='1'
      if($cancel){$env:HV_PRIORITY_ACTION_FAIL='1'}else{Remove-Item Env:HV_PRIORITY_ACTION_FAIL -ErrorAction SilentlyContinue}
      Remove-Item -LiteralPath (Join-Path $fixtureRoot ("child-BelowNormal-$(if($cancel){'cancel'}else{'success'}).json")) -Force -ErrorAction SilentlyContinue
      $result=Invoke-AdmissionFixture $fixtureGuard 'BelowNormal' ([switch]$cancel)
      Remove-Item Env:HV_PRIORITY_RESTORE_FAIL -ErrorAction SilentlyContinue
      Remove-Item Env:HV_PRIORITY_ACTION_FAIL -ErrorAction SilentlyContinue
      $fixtureLock=Join-Path $fixtureRuntime 'verify-lock.d'
      if(Test-Path -LiteralPath $fixtureLock){Remove-Item -LiteralPath $fixtureLock -Recurse -Force -ErrorAction SilentlyContinue}
      $diagnostics=@($result.output -split "`r?`n" | Where-Object { $_ -match 'admission priority restore failed; child launch is refused' })
      Assert-True ($result.exitCode -ne 0 -and $diagnostics.Count -eq 1) "restore failure has one diagnostic cancel=$cancel exit=$($result.exitCode) diagnostics=$($diagnostics.Count) output=$($result.output)"
      Assert-True (-not (Test-Path -LiteralPath $result.childOutput)) "restore failure launches no child cancel=$cancel"
      if($cancel){Assert-True ($result.output -match 'synthetic action failure') "action exception survives restore failure output=$($result.output)"}
      else {Assert-True ($result.output -match 'admission priority restoration could not be proven') 'successful action fails before child launch'}
      Write-Output "PASS heavy-verifier-priority restore-failure cancel=$cancel diagnostic=1 child=0"
    }
  } finally {
    Remove-Item Env:HV_PRIORITY_RESTORE_FAIL -ErrorAction SilentlyContinue
    $resolved=[IO.Path]::GetFullPath($fixtureRoot)
    Assert-True ((Split-Path -Parent $resolved).TrimEnd('\','/') -ceq ([IO.Path]::GetFullPath([IO.Path]::GetTempPath())).TrimEnd('\','/') -and (Split-Path -Leaf $resolved) -like 'heavy-verifier-priority-admission-*') 'safe real admission fixture cleanup'
    if(Test-Path -LiteralPath $resolved){Remove-Item -LiteralPath $resolved -Recurse -Force}
  }
}
if($runStructure){
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseInput($guard,[ref]$tokens,[ref]$errors)
Assert-True ($errors.Count -eq 0) 'heavy-verifier priority source parses'
$names=@('Enter-HeavyAdmissionPriority','Exit-HeavyAdmissionPriority','Invoke-HeavyAdmissionCensus')
$definitions=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $names -contains $node.Name},$true))
Assert-True ($definitions.Count -eq $names.Count) 'heavy-verifier priority helpers are present once'
$helperText=($definitions | Sort-Object Name | ForEach-Object { $_.Extent.Text }) -join "`n"
Assert-True ($helperText.Contains('PriorityClass]::Normal') -and $helperText.Contains('Exit-HeavyAdmissionPriority')) 'heavy-verifier priority helper raises and restores'
Assert-True (([regex]::Matches($guard,'Invoke-HeavyAdmissionCensus')).Count -ge 5) 'all eligibility/census calls use the priority wrapper'
Assert-True ($guard.Contains('deadline=210000') -and $guard.Contains('deadline=90000')) 'admission and census budgets remain unchanged'

$root=Join-Path ([IO.Path]::GetTempPath()) ('heavy-verifier-priority-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
try {
  $child=Join-Path $root 'child.ps1'
  Write-Text $child @'
param([string]$OutputPath)
[IO.File]::WriteAllText($OutputPath,[string][Diagnostics.Process]::GetCurrentProcess().PriorityClass)
'@
  $probeTemplate=@'
param([string]$Mode,[string]$Root)
$ErrorActionPreference='Stop'
$script:heavyAdmissionPriorityRaised=$false
$script:heavyAdmissionPriorityClass=$null
$script:heavyAdmissionPriorityDepth=0
$script:heavyAdmissionPriorityFailureReported=$false
$script:heavyAdmissionPriorityRestoreFailureReported=$false
{0}
function Assert-HeavyCallerEligibility {
  [IO.File]::WriteAllText((Join-Path $Root 'admission.txt'),[string][Diagnostics.Process]::GetCurrentProcess().PriorityClass)
  return 'admitted'
}
$original=[Diagnostics.Process]::GetCurrentProcess().PriorityClass
try {
  [Diagnostics.Process]::GetCurrentProcess().PriorityClass=[Diagnostics.ProcessPriorityClass]::$Mode
  $result=Invoke-HeavyAdmissionCensus { Assert-HeavyCallerEligibility }
  [IO.File]::WriteAllText((Join-Path $Root 'result.txt'),[string]$result)
  $child=Start-Process -FilePath (Join-Path $PSHOME 'pwsh.exe') -ArgumentList @('-NoProfile','-NonInteractive','-File','{1}',(Join-Path $Root 'child.txt')) -WindowStyle Hidden -PassThru
  $child.WaitForExit()
} finally { [Diagnostics.Process]::GetCurrentProcess().PriorityClass=$original }
'@
  $results=[Collections.Generic.List[string]]::new()
  foreach($mode in @('BelowNormal','Idle','Normal')) {
    $case=Join-Path $root $mode;[void][IO.Directory]::CreateDirectory($case)
    $probe=Join-Path $case 'probe.ps1';$childPath=$child.Replace("'","''")
    Write-Text $probe ($probeTemplate.Replace('{0}',$helperText).Replace('{1}',$childPath))
    $stderrPath=Join-Path $case 'stderr.txt'
    $sw=[Diagnostics.Stopwatch]::StartNew()
    $process=Start-Process -FilePath (Join-Path $PSHOME 'pwsh.exe') -ArgumentList @('-NoProfile','-NonInteractive','-File',$probe,$mode,$case) -WindowStyle Hidden -PassThru -RedirectStandardError $stderrPath
    $process.WaitForExit();$sw.Stop()
    Assert-True ($process.ExitCode -eq 0) "priority probe exits for $mode (stderr=$([IO.File]::ReadAllText($stderrPath)))"
    $admission=[IO.File]::ReadAllText((Join-Path $case 'admission.txt'))
    $childClass=[IO.File]::ReadAllText((Join-Path $case 'child.txt'))
    Assert-True ($admission -ceq 'Normal') "admission census raises $mode to Normal"
    Assert-True ($childClass -ceq $mode) "gate child inherits configured $mode after census"
    $results.Add("$mode admission=$admission child=$childClass duration=$([Math]::Round($sw.Elapsed.TotalSeconds,3))s")
  }
  $failed=Join-Path $root 'failed';[void][IO.Directory]::CreateDirectory($failed)
  $failureText=$helperText.Replace('$process.PriorityClass = [Diagnostics.ProcessPriorityClass]::Normal',"throw [UnauthorizedAccessException]::new('synthetic denied')")
  $probe=Join-Path $failed 'probe.ps1';Write-Text $probe ($probeTemplate.Replace('{0}',$failureText).Replace('{1}',$child.Replace("'","''")))
  $stderrPath=Join-Path $failed 'stderr.txt';$sw=[Diagnostics.Stopwatch]::StartNew()
  $process=Start-Process -FilePath (Join-Path $PSHOME 'pwsh.exe') -ArgumentList @('-NoProfile','-NonInteractive','-File',$probe,'BelowNormal',$failed) -WindowStyle Hidden -PassThru -RedirectStandardError $stderrPath
  $process.WaitForExit();$sw.Stop();$stderr=[IO.File]::ReadAllText($stderrPath)
  $diagnostics=@($stderr -split "`r?`n" | Where-Object { $_ -match 'admission priority raise failed; continuing at inherited class' })
  Assert-True ($process.ExitCode -eq 0 -and $diagnostics.Count -eq 1) 'failed priority raise remains fail-open with one diagnostic'
  Assert-True ([IO.File]::ReadAllText((Join-Path $failed 'result.txt')) -ceq 'admitted') 'failed priority raise does not refuse admission'
  $results.Add("failed-raise diagnostic=1 admission=admitted duration=$([Math]::Round($sw.Elapsed.TotalSeconds,3))s")
  $results | ForEach-Object { Write-Output "PASS heavy-verifier-priority $_" }
} finally {
  $resolved=[IO.Path]::GetFullPath($root)
  Assert-True ((Split-Path -Parent $resolved).TrimEnd('\','/') -ceq ([IO.Path]::GetFullPath([IO.Path]::GetTempPath())).TrimEnd('\','/') -and (Split-Path -Leaf $resolved) -like 'heavy-verifier-priority-*') 'safe heavy priority fixture cleanup'
  Remove-Item -LiteralPath $resolved -Recurse -Force
}
}
