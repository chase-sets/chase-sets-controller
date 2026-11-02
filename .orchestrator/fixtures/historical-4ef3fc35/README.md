# Historical controller fixture 4ef3fc35

Pinned to controller commit `4ef3fc35d82153f7751cf28a9a740d365f972688`. The pinned source object was absent from product main; bytes came from the existing public controller snapshot whose commit records this exact Source-Controller-Head.

The nine files below are the closed read set of the ordinary-dispatch baseline
in `Test-9334OrdinaryCarrier` in `interrupted-integration-test-support.ps1`.
It imports the evidence module (which dot-sources ownership), exercises its
state/command/source readers, then executes the historical launcher with a v2
ordinary resume binding. The launcher dot-sources routing, ownership, dispatch
contract and stream audit, imports evidence and fleet admission, and checks
that the preload/verifier paths exist before refusing the unsupported binding.

The refusal precedes prompt construction, owner publication and child launch.
No logger, consumer, helper execution, Node/heavy-verifier dependencies,
review/planning contracts, skills or tests are read by this baseline arm.
Routing policy/registry inputs come from the caller's isolated routing scope,
not from this historical tree.

Each entry is pinned to its raw Git blob; the `* -text` policy preserves those
bytes. The fixture loader and historical-fixture-manifest.check.ps1 verify the
exact file inventory and every blob before use; no candidate file fills a gap.

- .orchestrator/dispatch-claude-stream-audit.ps1 | blob `74815c670fddbec4c3e5d3c8b4707579003cd46d`
- .orchestrator/dispatch-lane.ps1 | blob `df3b49f78a067c9f26e5cf60e90c5153d6676097`
- .orchestrator/dispatch-ownership.ps1 | blob `812ae56aecfabc0a4c96f5bb566cf0c233ee4f99`
- .orchestrator/fleet-exclusive-admission.psm1 | blob `79146f3bf5b33e1263deffb53bf27523280df17c`
- .orchestrator/heavy-admission-preload.cjs | blob `99de2f76d0604144e43b93361f8502e90738f83c`
- .orchestrator/integration-dispatch-contract.ps1 | blob `65826774ddea756952e6fe195b6b47d6c6357dab`
- .orchestrator/invoke-heavy-verifier.ps1 | blob `9c8b8f812501f0c42b3fb41f28480d9157a5e7d4`
- .orchestrator/landed-integration-evidence.psm1 | blob `f5962c606c7cb047c31d61fce35a45ed27275291`
- .orchestrator/routing-data.ps1 | blob `120a19ced2f3d2039a52d0580730b28636f79485`
