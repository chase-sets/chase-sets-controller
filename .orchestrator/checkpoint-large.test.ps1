$ErrorActionPreference='Stop'
& (Join-Path $PSScriptRoot 'dispatch-history-large.test.ps1') -CheckpointOnly
