[CmdletBinding()]
param([ValidateSet('all','candidate','baseline','issue-scan','no-linkage','ten-item')][string]$Arm = 'all')
$ErrorActionPreference = 'Stop'
& (Join-Path $PSScriptRoot 'board-hourly-scale-part.ps1') -Arm $Arm
