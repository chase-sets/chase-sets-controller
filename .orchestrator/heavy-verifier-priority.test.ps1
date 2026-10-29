[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
function Assert-True([bool]$Value,[string]$Name) { if(-not $Value){throw "ASSERTION FAILED: $Name"} }
function Write-Text([string]$Path,[string]$Value) { [IO.File]::WriteAllText($Path,$Value,[Text.UTF8Encoding]::new($false)) }

$guard=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'invoke-heavy-verifier.ps1'))
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
$script:heavyAdmissionPriorityFailureReported=$false
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
