# Historical successor baseline aa62899

Pinned to controller commit `aa62899ecb923aa87a25ea8a312f7dffc6ed41e0`.
Only the four-file read closure of `BaselineModule9411` is retained. The evidence
module dot-sources ownership; its ordinary-source reader dot-sources the dispatch
contract, which loads the routing library in library mode. The baseline controls
do not launch its rebase helper or load routing policy/registry data. No private
history, Git metadata, runtime state, or unrelated historical files are included.

The tracked `* -text` policy preserves each original Git blob byte. The loader
checks every pin before the module is imported and refuses missing or changed
files. This fixture also removes the successor arms' hosted dependency on the
private object database.

- .orchestrator/landed-integration-evidence.psm1 | blob `cbf8424ab60f365887ec8f55ce876a4bb7a34964`
- .orchestrator/dispatch-ownership.ps1 | blob `f4074f8fe014fce58c4b68fe6875faa60e3c3414`
- .orchestrator/integration-dispatch-contract.ps1 | blob `65826774ddea756952e6fe195b6b47d6c6357dab`
- .orchestrator/routing-data.ps1 | blob `120a19ced2f3d2039a52d0580730b28636f79485`
