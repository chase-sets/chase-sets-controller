[CmdletBinding()]
param([ValidateSet('','no-priority','priority-at-top','throw-on-bad-config','missing-file-normal','ignore-override','ignore-file','bad-schema','bad-class')][string]$Mutant='')
$ErrorActionPreference='Stop'
function Assert-True([bool]$Value,[string]$Name) { if(-not $Value){throw "ASSERTION FAILED: $Name"} }
function Write-Text([string]$Path,[string]$Value) { [IO.File]::WriteAllText($Path,$Value,[Text.UTF8Encoding]::new($false)) }
function Replace-Once([string]$Source,[string]$Old,[string]$New) {
  Assert-True (([regex]::Matches($Source,[regex]::Escape($Old))).Count -eq 1) "fixture seam occurs exactly once: $Old"
  return $Source.Replace($Old,$New)
}
$root=Join-Path ([IO.Path]::GetTempPath()) ('lane-priority-test-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
. (Join-Path $PSScriptRoot 'routing-data-test-support.ps1')
$scope=Enter-RoutingDataTestScope
try {
  $runtime=Join-Path $root '.orchestrator'
  Copy-Item -LiteralPath $PSScriptRoot -Destination $runtime -Recurse
  $worktree=Join-Path $root 'lane-23';[void][IO.Directory]::CreateDirectory($worktree)
  foreach($arguments in @(@('init','--initial-branch=synthetic/priority'),@('config','user.name','Priority Test'),@('config','user.email','priority@example.invalid'))){
    & git -C $worktree @arguments | Out-Null;Assert-True ($LASTEXITCODE -eq 0) 'fixture git setup'
  }
  Write-Text (Join-Path $worktree 'seed.txt') 'seed'
  & git -C $worktree add seed.txt; & git -C $worktree commit -m seed | Out-Null
  Assert-True ($LASTEXITCODE -eq 0) 'fixture committed'
  $prompt=Join-Path $runtime 'prompt.txt';Write-Text $prompt 'synthetic priority probe'
  $child=Join-Path $runtime 'priority-child.ps1'
  Write-Text $child @'
param($Label)
$ErrorActionPreference='Stop'
$runtime=Split-Path -Parent $PSCommandPath
$self=[Diagnostics.Process]::GetCurrentProcess()
$grandchild=Start-Process -FilePath (Join-Path $PSHOME 'pwsh.exe') -ArgumentList @('-NoProfile','-NonInteractive','-Command','[Console]::Write([Diagnostics.Process]::GetCurrentProcess().PriorityClass)') -RedirectStandardOutput (Join-Path $runtime 'grandchild.txt') -WindowStyle Hidden -PassThru
$grandchild.WaitForExit()
$record=Get-Content (Join-Path $runtime "watchdog-lane-$Label.json") -Raw | ConvertFrom-Json -DateKind String
[IO.File]::WriteAllText((Join-Path $runtime 'observed.json'),(@{child=[string]$self.PriorityClass;grandchild=[IO.File]::ReadAllText((Join-Path $runtime 'grandchild.txt'));record=$record}|ConvertTo-Json -Depth 8))
exit 0
'@
  $dispatcher=Join-Path $runtime 'dispatch-lane.ps1'
  $source=[IO.File]::ReadAllText($dispatcher)
  $old='@("exec", "-m", $Model, "-c", "model_provider=account_pool", "-c", "model_reasoning_effort=$Effort", "-c", "features.apps=false", "--json",' + "`r`n" + '      "--dangerously-bypass-approvals-and-sandbox", "-C", $worktreeResolved, "-")'
  $source=Replace-Once $source $old '@("-NoProfile", "-NonInteractive", "-File", (Join-Path $PSScriptRoot "priority-child.ps1"), $Label)'
  $setter='[Diagnostics.Process]::GetCurrentProcess().PriorityClass = $lanePriority.priorityClass'
  switch($Mutant){
    'no-priority' { $source=Replace-Once $source $setter '# mutant omits priority application' }
    'priority-at-top' {
      $source=Replace-Once $source $setter '# mutant applies priority too early'
      $source=Replace-Once $source '$ErrorActionPreference = "Stop"' ('$ErrorActionPreference = "Stop"'+"`r`n"+'[Diagnostics.Process]::GetCurrentProcess().PriorityClass = "BelowNormal"')
    }
    'throw-on-bad-config' {
      $source=Replace-Once $source "return @{ priorityClass='Normal'; prioritySource='fallback:unreadable-or-invalid-json' }" 'throw'
    }
    'missing-file-normal' {
      $source=Replace-Once $source "return @{ priorityClass='BelowNormal'; prioritySource='default' }" "return @{ priorityClass='Normal'; prioritySource='default' }"
    }
    'ignore-override' { $source=Replace-Once $source 'if ($Override)' 'if ($false)' }
    'ignore-file' {
      $source=Replace-Once $source "return @{ priorityClass=[string]`$configuration.priorityClass; prioritySource='file' }" "return @{ priorityClass='BelowNormal'; prioritySource='file' }"
    }
    'bad-schema' { $source=Replace-Once $source "if (`$configuration.schemaVersion -cne 'lane-priority/v1')" 'if ($false)' }
    'bad-class' {
      $source=Replace-Once $source "return @{ priorityClass='Normal'; prioritySource='fallback:priorityClass' }" "return @{ priorityClass='Idle'; prioritySource='fallback:priorityClass' }"
    }
  }
  Write-Text $dispatcher $source
  $runner=Join-Path $root 'runner.ps1'
  Write-Text $runner @'
param($Runtime,$Worktree,$Label,$Override)
$ErrorActionPreference='Stop'
$global:priorityProbeRuntime=$Runtime
# A debugger probe observes the real admission and ownership scan without
# changing either production implementation. Its census uses the real reader.
Set-PSBreakpoint -Command Assert-DispatchAdmissionClean,Invoke-DispatchOwnershipScavenge -Action {
  $priority=[string][Diagnostics.Process]::GetCurrentProcess().PriorityClass
  $census=Get-LiveDispatchOwnership -RuntimeRoot $global:priorityProbeRuntime -TempRoot (Split-Path -Parent $global:priorityProbeRuntime) -ContainerRoot (Split-Path -Parent $global:priorityProbeRuntime)
  [IO.File]::AppendAllText((Join-Path $global:priorityProbeRuntime 'prelaunch.jsonl'),((@{priority=$priority;health=$census.health.status}|ConvertTo-Json -Compress)+[Environment]::NewLine))
} | Out-Null
$parameters=@{Harness='codex';Model='gpt-6.1-sol';Effort='high';LaneRole='implementation';Row=4;Placement='provisional';Issue=90232;PromptFile=(Join-Path $Runtime 'prompt.txt');Worktree=$Worktree;Label=$Label;ExecutablePath=(Join-Path $PSHOME 'pwsh.exe')}
if($Override){$parameters.PriorityClass=$Override}
& (Join-Path $Runtime 'dispatch-lane.ps1') @parameters
exit $LASTEXITCODE
'@
  $cases=@(
    @{name='default';expected='BelowNormal';source='default'},
    @{name='idle';config='{"schemaVersion":"lane-priority/v1","priorityClass":"Idle"}';expected='Idle';source='file'},
    @{name='normal';config='{"schemaVersion":"lane-priority/v1","priorityClass":"Normal"}';expected='Normal';source='file'},
    @{name='override';config='{"schemaVersion":"lane-priority/v1","priorityClass":"Idle"}';override='Normal';expected='Normal';source='parameter'},
    @{name='schema';config='{"schemaVersion":"wrong","priorityClass":"Idle"}';expected='Normal';source='fallback:schemaVersion'},
    @{name='high';config='{"schemaVersion":"lane-priority/v1","priorityClass":"High"}';expected='Normal';source='fallback:priorityClass'},
    @{name='unknown';config='{"schemaVersion":"lane-priority/v1","priorityClass":"Surprise"}';expected='Normal';source='fallback:priorityClass'},
    @{name='json';config='{';expected='Normal';source='fallback:unreadable-or-invalid-json'},
    @{name='unreadable';config='{"schemaVersion":"lane-priority/v1","priorityClass":"Idle"}';locked=$true;expected='Normal';source='fallback:unreadable-or-invalid-json'}
  )
  $mutantCase=@{'no-priority'='default';'priority-at-top'='default';'throw-on-bad-config'='unreadable';'missing-file-normal'='default';'ignore-override'='override';'ignore-file'='idle';'bad-schema'='schema';'bad-class'='high'}
  if($Mutant){$cases=@($cases | Where-Object name -EQ $mutantCase[$Mutant])}
  foreach($case in $cases){
    $config=Join-Path $runtime 'lane-priority.json';$observed=Join-Path $runtime 'observed.json';$probe=Join-Path $runtime 'prelaunch.jsonl'
    foreach($path in @($config,$observed,$probe)){if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path -Force}}
    if($case.config){Write-Text $config $case.config}
    $lock=$null;$process=$null
    try {
      if($case.locked){$lock=[IO.File]::Open($config,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}
      $label='priority-'+$case.name
      $args=@('-NoProfile','-NonInteractive','-File',$runner,$runtime,$worktree,$label)
      if($case.override){$args+=@($case.override)}
      $out=Join-Path $root "$label.out";$err=Join-Path $root "$label.err"
      $process=Start-Process -FilePath (Join-Path $PSHOME 'pwsh.exe') -ArgumentList $args -WindowStyle Hidden -PassThru -RedirectStandardOutput $out -RedirectStandardError $err
      $process.WaitForExit()
      Assert-True ($process.ExitCode -eq 0 -and (Test-Path $observed)) "bad configuration never blocks launch (case=$($case.name); exit=$($process.ExitCode); stderr=$([IO.File]::ReadAllText($err)))"
      $data=Get-Content $observed -Raw | ConvertFrom-Json -DateKind String
      $prelaunch=@(Get-Content $probe | ConvertFrom-Json)
      Assert-True ($prelaunch.Count -ge 2 -and @($prelaunch | Where-Object {$_.priority -cne 'Normal' -or $_.health -cne 'ok'}).Count -eq 0) "prelaunch admission and ownership census stay Normal (observed=$($prelaunch | ConvertTo-Json -Compress))"
      Assert-True ($data.child -ceq $case.expected -and $data.grandchild -ceq $case.expected) "child and descendant inherit configured class (case=$($case.name))"
      Assert-True ($data.record.priorityClass -ceq $case.expected -and $data.record.prioritySource -ceq $case.source) "launch record exposes applied class and source (case=$($case.name))"
      $spec=Get-Content (Join-Path $runtime "watchdog-lane-$label.json") -Raw | ConvertFrom-Json
      Assert-True ($spec.priorityClass -ceq $case.expected -and $spec.prioritySource -ceq $case.source) 'durable launch spec retains priority after release'
      Assert-True (@(Get-ChildItem -LiteralPath $runtime -Filter 'dispatch-launch-*.json').Count -eq 0) 'real dispatch releases exact launch ownership'
      Write-Output "PASS priority $($case.name) child=$($data.child) descendant=$($data.grandchild) source=$($data.record.prioritySource) census=Normal"
    } finally {if($lock){$lock.Dispose()};if($process){if(-not $process.HasExited){$process.Kill();$process.WaitForExit()};$process.Dispose()}}
  }
} finally {
  Exit-RoutingDataTestScope $scope
  $resolved=[IO.Path]::GetFullPath($root)
  Assert-True ((Split-Path -Parent $resolved).TrimEnd('\','/') -ceq ([IO.Path]::GetFullPath([IO.Path]::GetTempPath())).TrimEnd('\','/') -and (Split-Path -Leaf $resolved) -like 'lane-priority-test-*') 'safe fixture cleanup'
  Remove-Item -LiteralPath $resolved -Recurse -Force
}
