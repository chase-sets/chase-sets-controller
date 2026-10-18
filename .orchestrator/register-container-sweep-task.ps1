<#
.SYNOPSIS
Register the hidden "ChaseSets Container Sweep" scheduled task (every six hours).

.DESCRIPTION
The delivery loop runs container-sweep.ps1 every cycle; this task is the
fallback for when the loop is idle. It launches run-container-sweep.vbs through
wscript.exe so no console window opens. Re-running replaces the task.
#>
[CmdletBinding(SupportsShouldProcess)]
param([string]$TaskName = 'ChaseSets Container Sweep', [int]$EveryHours = 6)
$ErrorActionPreference = 'Stop'
$launcher = Join-Path $PSScriptRoot 'run-container-sweep.vbs'
if (-not (Test-Path -LiteralPath $launcher -PathType Leaf)) { throw "launcher missing: $launcher" }
[void][IO.Directory]::CreateDirectory((Join-Path $PSScriptRoot 'logs'))
$action = New-ScheduledTaskAction -Execute (Join-Path $env:WINDIR 'System32\wscript.exe') -Argument "//B //NoLogo `"$launcher`""
$trigger = New-ScheduledTaskTrigger -Once -At ((Get-Date).Date.AddHours((Get-Date).Hour + 1)) -RepetitionInterval (New-TimeSpan -Hours $EveryHours)
$settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 4) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
if ($PSCmdlet.ShouldProcess($TaskName, 'Register scheduled task')) {
  Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Description 'Hidden fallback run of .orchestrator/container-sweep.ps1 -Apply (six-hour due gate).' -Force | Out-Null
  Get-ScheduledTask -TaskName $TaskName | Get-ScheduledTaskInfo | Select-Object TaskName, NextRunTime
}