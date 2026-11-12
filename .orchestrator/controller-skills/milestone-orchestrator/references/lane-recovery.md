# Watcher failure and lane recovery

Read for a watcher failure, membership transition or refused relaunch only.
`lane-stall-watchdog-batch.ps1` and `lane-stall-watchdog.ps1` own result schemas.

The native PS7 batch defaults to 120-second polls, three unchanged observations,
7200-second window. Growth resets the unchanged count, not unresolved reducer
failure. `WINDOW_EXPIRED` means expiry only; re-arm while work remains.
`TRANSPORT_FAILURE` requires manual bounded observation until restored; the
retained shell shim is not an alternative health monitor.

Per-lane reducer failures (`REDUCER_EXIT`, `RESULT_INVALID`,
`WATCHDOG_RELAUNCH_WINDOW_EXPIRED`) do not stop sibling observation. Diagnose
the named lane; only a later valid non-duplicate reduction clears its unresolved
failure. Positive `unresolvedReducerFailures` is nonzero exit, not health or
`ALL_TERMINAL`. Preserve actual exit reason. A membership edit makes old watcher
exit `MEMBERSHIP_CHANGED` at next boundary; wait before replacement. A canonical
relaunch follows its replacement transcript; re-arm with new progress path.

The reducer observes every role. `LIVE_SLOW`, `LAUNCH_PENDING`, `LAUNCH_FAILED`
and `OWNERSHIP_UNKNOWN` keep observation active. A stopped, proven-dead planning,
review or decision lane is `OBSERVATION_ONLY`, not vacancy/relaunch authority.
Implementation mechanical death uses retained canonical launch provenance and
same partial work. Missing/ambiguous/wrong-head dispatch bindings refuse rather
than invent row/fallback. No account on source provider permits only the current
qualified other-provider fallback. `NO_QUALIFIED_FALLBACK` and `HARNESS_CEILING`
go to host diagnosis. A launch counts only after exact start/ownership ack;
failed launch stays retryable without relaunch/attempt increments.

Ownership schema-v4 (ordinary) and v5 (interrupted integration) retain launchId,
label, canonical runtime/transcript and launcher/child creation identity. Only
exact owner exit releases occupancy. Reused PID alone, malformed/legacy-live
records, multiple candidates or possible descendants retain unknown occupancy.
Never infer safety from transcript silence or wrapper exit.
