# Duration-balanced controller CI

The required battery inventory and its identities are unchanged. The adapter
keeps `inventory`/`selected` as required identities and adds `executionItems`
with explicit `requiredIdentity` mappings. Shards execute those items serially.
Merge requires every planned shard receipt and every execution item exactly
once; all parts must pass before their original required identity can pass.
Part results, raw-log locations, and predicted durations remain in the final
receipt. Legacy plans without `executionItems` retain their original merge.

## Bounded shard count (#9272)

The runner binds one shard count, `$CiShardCount` in `controller-ci.ps1`, into
every plan it writes as `shardCount`. The workflow matrix, `-Shard` validation,
LPT loads and Merge receipt cardinality all read the plan's count; no other
ten-shard literal remains. `$CiShardCount` is the smallest of 16, 17 and 18
whose calibrated LPT replay has a planned maximum of at most 250 s (300 s over
a 1.2 variance margin; 18 is the Free-plan concurrency cap). It is a reviewed
constant, never scaled at run time. A plan without `shardCount` predates it and
merges as exactly ten receipts; any other recorded count refuses. The workflow
is unchanged because its matrix already comes from the plan.

## Parts

`controller-ci-parts.json` maps split identities to named parts. Part weights
are uniform placeholders: they only feed `*-split-estimate` timings, which the
gate plan must not contain, and no hand weight survives.

- Board hourly scale splits by its existing `-Arm` selector. The legacy test
  delegates to the shared part runner: candidate includes the same-fixture
  inert convergence pass; baseline, issue-scan and no-linkage retain 2400
  items; ten-item retains both controls. Scale support is byte-equal to B.
- Landed integration adds `-Part product-census|authority|dispatch|collector|ownership`.
  Each named part selects a disjoint region with its own original setup.
- Dispatch routing data adds `-Part` with eight parts. Fifteen cases are
  selected by a per-case filter, the eight routing mutants by one gated block,
  and the 24 capacity mutants by a per-mutant filter.
- Cleanup orphan worktree dirs adds `-Part` with six gated regions. Part
  `scale` alone keeps the whole 200x2000 fixture, its 12-minute construction
  bound, the <60 s report and the 300000 ms AC6 assertions.

`suite-parts.ps1` holds the single routing/cleanup part map; every key has
exactly one owning part and even `-Part all` resolves its owner, so a broken
map fails closed. Default `-Part all`, `-Case` (including mutant child
self-calls) and `-CapacityMutantsOnly` keep B behavior. Named parts combined
with a legacy selector refuse. Helpers are not `*.test.ps1` files, so they never
become required identities.

## Timing profile

LPT schedules longest estimated durations first onto the least-loaded shard.
Ordinal execution identity breaks equal-duration ties; the lowest shard number
breaks load ties. Restricted items remain LOCAL_ONLY, never PASS. Missing,
malformed, duplicate, future, or older-than-30-day records use a deterministic
30000 ms fallback. Otherwise valid source-mismatched records keep their
elapsedMs as `stale-recorded`; a part's own record (`recorded-part` or
`stale-recorded-part`) outranks any share of its parent. Source hashes
normalize CRLF to LF.

`controller-ci-record-durations.ps1 -FinalResultPath <final.json> -OutputPath
<profile.json>` records the maximum elapsedMs per identity within its input
finals, with source heads, hashes, timestamps and run IDs. Record calibration
and history separately, then compose:

    & .orchestrator/controller-ci-compose-durations.ps1 -CalibrationProfile cal.json -HistoricalProfile old.json -OutputPath .orchestrator/controller-ci-durations.json

Composition keeps every calibration record and only historical records
outside the remeasured routing, cleanup and board families, so superseded
whole-parent and cold part records can never outrank calibration. Surviving
records keep their original provenance. The committed profile is H' run
38037840987 composed with no calibration yet: 74 records, landed parts kept.

`controller-ci-prediction.ps1` performs a library-only dry plan against the
hosted restriction set, replays LPT at 16, 17 and 18 shards, and prints the
timing-source census. Its gate requires zero `fallback`/`*-split-estimate`
sources, every calibration record planned at its value (`-CalibrationProfile`),
attributable records otherwise, and the selected count equal to the runner's.
It exits non-zero until the gate is met. It never executes test items.

## Proofs

`controller-ci-coverage.check.ps1` reads immutable B blobs (routing
`b8d4d804`, cleanup `8610bd4d`, board `4eedaa85`), proves each split equals B
plus a fixed plumbing grammar, enumerates cases, mutants and assertions from
the blobs rather than the map or manifest, and runs named drop, duplicate and
misassignment controls. With `-PartResultDirectory` (hosted shard receipts) or
`-PartLogs`, it also proves the part logs repeat every whole-suite PASS line
exactly once. `controller-ci-sharding.check.ps1` runs the refusal matrix: each
control is green on the real library and its named bypass mutant turns it red.
It also re-merges retained B/H' receipts unchanged as legacy ten-shard plans.
Their `.check.ps1` names deliberately add no required battery test.

## Runner packaging

The workflow executes `runner/.orchestrator/controller-ci.ps1` from public main,
not the candidate checkout's adapter. The host publishes the reviewed
`controller-ci.ps1` and `controller-ci-planning.ps1` to the trusted public runner
lineage after exact-head review. The candidate snapshot supplies its parts
manifest, timing profile and test sources. This lane does not publish or
dispatch.

Predictions are not hosted proof. The host owns AC3's unchanged B/H'
split/aggregate board control, AC5 calibration, and the AC6 fresh paired gate
with observed required/LOCAL_ONLY parity and measured shard and workflow times.
The issue-scan censor family stays with #8620.
