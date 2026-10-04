#!/usr/bin/env bash
# Windows supervision is native. A legacy WSL call is not lane-health evidence.
printf '%s\n' 'TRANSPORT_FAILURE: NATIVE_BATCH_REQUIRED; use native PowerShell 7 lane-stall-watchdog-batch.ps1 -LanesPath <absolute-json-path>' >&2
exit 1
