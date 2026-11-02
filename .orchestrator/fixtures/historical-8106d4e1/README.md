# Historical controller fixture 8106d4e1

Pinned to controller commit `8106d4e12c4b3329e3b59372366c5a57e8dfacc1`. Source bytes were read from the authorized product main checkout; no live object database is consulted by the fixture loader.

The 13 files below are the closed read set of `Test-7962NativeControls` in
`integration-dispatch-test-support.ps1`. Its baseline-late-head control and
`New-RetainedCase` execute the producer and launcher; the retained child calls
`rebase-integration.ps1` with an invalid parameter to record the historical
parameter stop. The producer imports ownership, review and rebase evidence,
invokes the logger, and the launcher imports stream audit and fleet admission.
The launcher also checks the preload/verifier paths and calls the consumer on
exit; the consumer imports the same helpers. The logger imports the log lock,
which `Set-ArchivedOrchestrationLogMutexName` reads and rewrites only in the
copied runtime.

All baseline launches are implementation lanes with a PowerShell test child:
review/planning contracts and Node/heavy-verifier execution dependencies are
not read. Board synchronization is disabled by the caller's `-NoBoard` and
explicit history path. Tests, skills, unrelated fixtures and controller tools
are not part of this read set.

Each entry is pinned to its raw Git blob; the `* -text` policy preserves those
bytes. The fixture loader and historical-fixture-manifest.check.ps1 verify the
exact file inventory and every blob before use; no candidate file fills a gap.

- .orchestrator/dispatch-claude-stream-audit.ps1 | blob `74815c670fddbec4c3e5d3c8b4707579003cd46d`
- .orchestrator/dispatch-lane.ps1 | blob `42479c82d595b3da1b1188a605b1ce4dfd717b81`
- .orchestrator/dispatch-ownership.ps1 | blob `3609a61bd730b12122434268bc9a4192f1794cc8`
- .orchestrator/fleet-exclusive-admission.psm1 | blob `887172f0e7d27ac429ccccf9a3534a26e267407d`
- .orchestrator/heavy-admission-preload.cjs | blob `7cb9585f3cfb5a5da66dee417a9da306a9d441cb`
- .orchestrator/invoke-heavy-verifier.ps1 | blob `823380e4b421fe8ac7cdb47c4aabf18e96e147d7`
- .orchestrator/landed-integration-consume.ps1 | blob `2ff5c7239854b78d8adeb9e23880a61d884d2097`
- .orchestrator/landed-integration-dispatch.ps1 | blob `0f30ef7bdc62b1eb9cc9e80adfe56a33df3c3269`
- .orchestrator/landed-integration-evidence.psm1 | blob `98649ea7323d73748be2ee1a9a9378b052f4ebc5`
- .orchestrator/log-event.ps1 | blob `2594d74ce81bad319e9014dc79c65299baeee7ab`
- .orchestrator/orchestration-log-lock.psm1 | blob `893c53ff42a7c9181e5a29b6462b9853e8841e7e`
- .orchestrator/rebase-integration.ps1 | blob `503c4192b11f193d28b8d777359b64eb0d66ccf4`
- .orchestrator/review-head-contract.psm1 | blob `c79b0288e1d76db88c139727501f1545114dbd11`
