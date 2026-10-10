# Duration-balanced controller CI

The required battery inventory and its identities are unchanged. The adapter
keeps `inventory`/`selected` as required identities and adds `executionItems`
with explicit `requiredIdentity` mappings. Ten shards execute those items
serially. Merge requires all ten receipts and every execution item exactly once;
all parts must pass before their original required identity can pass. Part
results, raw-log locations, and predicted durations remain in the final receipt.
Legacy plans without `executionItems` retain their original merge behavior.

`controller-ci-parts.json` partitions board hourly scale by its existing `-Arm`
selector. The legacy test delegates to the byte-preserved shared part runner:
candidate includes the same-fixture inert convergence pass; baseline,
issue-scan, and no-linkage retain 2400 items; ten-item retains both controls.
No scale-support assertions, fixture rows/specs, deadlines, or budgets change.

Landed integration adds `-Part product-census|authority|dispatch|collector|ownership`.
Its original assertions and fixture statements are unchanged. Each named part
selects a disjoint region with its own original setup. Default/legacy selectors
remain available. Named parts cannot combine with legacy partial switches.

LPT schedules longest estimated durations first onto the least-loaded shard.
Ordinal execution identity breaks equal-duration ties; the lowest shard number
breaks load ties. Restricted items remain LOCAL_ONLY, never PASS. Missing,
malformed, duplicate, future, or older-than-30-day records use a deterministic
30000 ms fallback. Otherwise valid source-mismatched records retain their recorded
elapsedMs as a deterministic estimate with timingSource `stale-recorded`.
Source hashes normalize CRLF to LF.

`controller-ci-durations.json` records the maximum observed elapsedMs per identity
from hosted runs 37231788164 and 37233541379, with source heads, source hashes,
timestamps, and run IDs. Otherwise valid records for changed sources remain
`stale-recorded` estimates; missing or invalid records still fall back.
The two mechanically split parents have explicit reviewed source-compatibility
hashes in the parts manifest. Board weights use the slow run's actual arm clocks
plus estimated fixture/reference/setup work. Landed weights are estimates, not
measured part durations. Fresh part elapsedMs can supersede parent estimates.

`controller-ci-record-durations.ps1 -FinalResultPath <final.json paths> -OutputPath
<profile.json>` refreshes the profile from retained hosted evidence and its local
source history. It does not download, publish, dispatch, or accept a release.
`controller-ci-prediction.ps1` performs a library-only dry plan, compares the
baseline/candidate required sets, and writes the predicted shard table. It never
invokes the release battery, executes test items, or bypasses hosted-only guards.

Focused proofs are `controller-ci-coverage.check.ps1` and
`controller-ci-sharding.check.ps1`. Their `.check.ps1` names deliberately do not
add or rename any required battery test. The coverage check compares original
sources and assertion bodies, then checks the complete board call union and the
landed region union without running heavy fixtures. The sharding check includes
the existing adapter's merge controls plus duration, LPT, and split controls.

## Runner packaging

The workflow executes `runner/.orchestrator/controller-ci.ps1` from public main,
not the candidate checkout's adapter. The host must include this reviewed
`controller-ci.ps1` and `controller-ci-planning.ps1` in the trusted public runner
lineage before the authorized candidate run. The candidate snapshot supplies
its parts manifest, timing profile, and test sources. Matrix shape stays ten
shards, so no workflow edit is required. This lane does not publish or dispatch.

Predictions are not hosted proof. The host owns the fresh exact-head full run,
PREEXISTING-11 comparison, required/satisfied inventory parity, observed shard
wall times, and the normal baseline-aware controller-release acceptance chain.
The existing issue-scan variance defect (#8620) is unchanged.
