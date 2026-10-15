# Model onboarding and experiments (historical record)

**Retired as a process on 2026-09-07 (model-routing v4.12, Todd).** Trials,
shadow pairs, provisional placements, per-trial budgets, and this ledger no
longer govern anything. Challengers enter a row through a quota rule in the
routing skill's row table, and a scheduled rebalance (every two weeks and on
any model release) promotes or demotes from the matrix's generated blocks.
P1 and P4 are closed as unadjudicable (P1's cost arm tripped 2026-07-27 and was
never decided; P4 could never be costed per effort level under the per-model
pooling that v4.13 removed — the effort step it asked about now enters a row
as an ordinary challenger quota, see the routing skill's row 4). P7 and the
row-2 Luna trial became the row-table quotas. The host trials are retired; host
choice is the row-9 rotation rule. Everything below is history: do not load
it for dispatch, placement, or onboarding.

**Status as of v4.11 (Todd, 2026-09-07).** P2 **failed**: Opus 5 row-7 author
block rate 0.84 (n=19) exceeds its 0.80 kill threshold; provisional row-7
authorship is withdrawn and row 7 defaults to Sol high with Fable 5.1 admitted
under the reserve. P5 **resolved against Opus 5 on recall** (CodeRabbit 55.2%
vs Sol 69.7%); row 11 stays Sol high with Opus 5 fallback. P6 **resolved for
Opus 5 on precision** (CodeRabbit 39.3% vs 35.2%; local reviewer block
tendency 0.56 vs Sol 0.74); Opus 5 high is the row-12 incumbent. P3
**retired**: the Sol-versus-Opus agentic comparison is superseded by the
ten-dispatch Astra high trial on rows 4, 5, and 10 (see the routing skill,
"Astra trial"). P1 and P4 stay open. New: row-2 Luna medium trial on scoped
fixes under 60K input until n=20. Fable 5 figures below are historical.

## Contents

- Onboarding a new model
- Active experiments

## Onboarding a new model

Frontier models arrive ~monthly. **No internal data means *unproven row*, not *no
row*** — waiting for measurement guarantees running a generation behind. Place on
arrival, then challenge the guess.

**What makes it safe:** provisional placement is allowed in any **lane** row, and
**never** in the host seat (row 9) or as a tier-3 rung on an irreversible artifact.
A wrong lane guess costs one review cycle and the external validator catches it; a
wrong host guess costs a 5-layer breaker and 325 unsupervised commits.

**Stages.** Trigger = availability → assign a new exact version its own empty
evidence cells (never copy the predecessor) → **gates first** (a gate failure ends it, no
benchmark reading) → provisional placement from the pre-committed map below →
**register a prediction with a number and a kill condition before first dispatch**
→ challenge paired against the incumbent on the same artifact class, serialized
against running trials → adjudicate at the recompute: ratify / revert /
re-authorize. There is no fourth "leave it and see".

**Rigor tiers** — most of this must cost nothing or it won't survive the cadence.
**A** paper placement (hours, zero dispatch): every model. **B** passive challenge
(zero marginal cost): the default — the challenger takes real work at its
provisional row and the dispatch log accumulates n. **C** active trial (budgeted,
capped): rare — contested rows or the host seat only.

**Benchmark → row map. Pre-committed: never re-pick a benchmark after seeing
scores** — that is retro-fitting evidence to the row you already wanted.

| Row | Governing evidence |
|---|---|
| 1 | $/token + internal gold set |
| 2/3 | SWE-Bench Verified, AA coding index |
| 4/5 | Terminal-Bench, Frontier-Bench, Agents' Last Exam |
| 6 | OSWorld |
| 7 | SWE-Bench Pro, DeepSWE, CursorBench |
| 8 | GDPval-AA, AA intelligence index |
| 11 | CodeRabbit recall split |
| 12 | CodeRabbit precision split |
| 14/15 | EQ-Bench, LMArena, WebDev Arena Elo |

**Placement rule:** a challenger provisionally takes a row when it is ≥ incumbent
on that row's governing benchmark at ≤ incumbent price, or ≥ price-parity with a
material benchmark gain. Everything else stays put. **A benchmark that contradicts
vendor positioning wins** — that is why the map is pre-committed.

**Expiry:** provisional rows expire at the next recompute. Un-adjudicated rows
automatically revert only to an incumbent configuration permitted by every
governing availability reserve; availability-reserve vetoes are authoritative,
and expiry never auto-promotes. Sol high is the current rows 7/8 incumbent and
reversion target. Existing Fable row-7 and row-8 figures below are historical
comparators only, not current incumbents or reversion targets.

## Astra selection (2026-09-04)

Todd authorized adding Astra as a task and orchestration option. Exact selector
`gpt-6-astra` has separate empty evidence cells. Task selection supports low,
medium, high, xhigh, and max; host selection starts at high through the
registered `astra-high` arm. This registration does not launch a trial or
promote Astra to the default. Before first live dispatch record the numerical
prediction, kill condition, and budget; compare against Sol on the same task
class. Host evaluation uses the existing cost/landing, throughput, stall,
routing-violation, and decision-latency metrics with daily/$150 rotation.

## Active experiments

Opened 2026-07-24 and extended 2026-07-25 (Opus 5). Each closes at the next
recompute. P1, P4, and P7 are the active experiments. P2 (failed), P3
(retired), P5 (resolved for Sol), and P6 (resolved for Opus 5) are closed as of
2026-09-07; their rows below are historical records and no longer bind
dispatch.

| # | Row | Claim | Kill | Cap |
|---|---|---|---|---|
| P1 | 8 | ≥ Fable's decision-completeness at ≤50% USD/artifact | 2 incomplete artifacts at n≥4, or USD/artifact >~$5 at n≥3 | $40 |

**P1's cost arm has crossed its kill line (2026-07-27).** On the row-8 cell at
production n, Opus 5 is not at ≤50% of Fable's USD/artifact — it is at parity or
slightly above, and over the absolute trip-wire. The completeness arm is not
what failed and is not disputed here. Adjudicate at the recompute: kill and
revert row 8 to Sol high, or re-authorize explicitly on completeness with the cost
claim withdrawn — but do not leave the original ≤50% wording standing, because
it is now false. Read the cell from `measuredAt.byRowModel`, never from
`byRow` (which pools Fable and Opus together on the very row being judged).
| P2 | 7 | **CLOSED, FAILED 2026-09-07.** Was: author block rate ≤ Fable's **0.80** at ≤60% USD/artifact | Tripped: 0.84 at n=19 | $150 |
| P3 | 5 | **RETIRED 2026-09-07**, superseded by P7. Was: block rate ≤ Sol's **0.42** at ≤ Sol's USD/artifact | — | $150 |

**Thresholds restated at the 2026-07-24 recompute.** P2 was written against Fable
0.86 (n=8) and P3 against Sol 0.77 (n=26); both came from an un-canonicalized,
un-stratified count that also scored indeterminate outcomes as passes. Corrected:
Fable's **row-7** rate is 0.80 (n=10); Sol's **row-4** rate is 0.42 (n=57) — used
as P3's nearest-neighbour proxy because row 5 has no review sample yet. Do not
re-quote the old figures.

**The v4.2 identity repair corroborates these thresholds rather than moving
them.** With version-explicit spellings restored, Fable's row-7 rate recomputes
to exactly the pre-registered 0.80 (n=10); before the repair the same query
returned a thinner, different number. That is evidence the repair recovered real
rows rather than inventing them. Sol's row-4 figure has since moved on new data,
but **the thresholds stay as written** — re-picking a threshold after seeing
scores is the retro-fit this rubric forbids. Compare against the pre-registered
number; read the incumbent's current figure from the matrix.

**P2 closed as failed (2026-09-07).** The 2026-07-27 reading (far under 0.80 at
small n) did not hold: Opus 5's row-7 author block rate reached 0.84 at n=19,
above the pre-registered 0.80 ceiling with n past the kill test's n≥8. The cost
arm was never adjudicated because the Fable row-7 cost sample stayed too thin;
it is moot. Effect: row 7 defaults to Sol high, Fable 5.1 high is admitted for
the named row-7 slices under the reserve, and Opus 5's provisional row-7
authorship is withdrawn.
| P4 | 6/7/8 | One effort level below the row default holds quality | any quality regression vs the row default | — |
| P5 | 11 | **RESOLVED 2026-09-07, Sol retained.** Was: Opus 5 high produces repair-ready high-recall reviews at least as complete as Sol high | Decided on CodeRabbit's model-level recall (Opus 5 55.2% vs Sol 69.7%); no local shadow pair was run | $120 |
| P6 | 12 | **RESOLVED 2026-09-07, Opus 5 high incumbent.** Was: Opus 5 high produces repair-ready precision reviews at least as actionable as Sonnet 5 medium | Decided on CodeRabbit's model-level precision (Opus 5 39.3% vs its production baseline 35.2%) plus local reviewer block tendency (0.56 vs Sol 0.74); no exact opus5-high vs sonnet5-medium pair exists, so the matrix cell stays null until local M | $80 |
| P7 | 4/5/10 | Astra high author block rate ≤ Sol's row-4 **0.42** at ≤ Sol's USD/artifact (Todd 2026-09-07; basis Terminal-Bench 4.0 57.7 vs 37.3, ALE 59.3 vs 53.6, Terminal-Bench-Science 64.6 vs 22.4) | >0.42 at n≥8, or two consecutive mechanical harness failures | 10 dispatches, ~$250 |

Every threshold above is a **ceiling, not a target**, and all rest on small n —
read the current figure from `measuredAt.blockRateByRow`, never from this page.

**Host trial:** Sol high vs Sonnet 5 high, alternating ~3-day blocks, under the
daily rotation rule; Fable excluded per row 9. **Opus 5 high is a registered
third arm (2026-07-24), awaiting a go** — start only via
`.orchestrator/start-host-trial.ps1 -Arm opus5-high -Register`, which pre-flights
the lease and model pin, and only with `host-trial-opus5-guardrails.md` pasted
in. It is a **tier-C active trial**, the only sanctioned route into this seat for
a model with no host data; provisional placement here stays forbidden. Its lane
numbers do not transfer — a host session is a different workload — so the arm
measures host cost directly, at a tightened ~$100 rotation.
Pre-registered: orchestrator $/landed-PR, landings/day, orchestrator-caused
stalls, routing violations per 100 dispatches, decision latency p50. Ties → cheapest.

**Version boundary correction (Todd, 2026-07-25):** Opus 4.8 review rejection is
deprecated with that exact model and does not transfer to Opus 5. Any historical
review evidence without an exact reported version is excluded. P5/P6 establish
Opus 5's own review evidence.

**Closed:** Row-4→Fable exploration trial **retired 2026-07-24** — Opus 5 leads Fable on the
row-4/5 governing benchmarks, so a Fable arm there was dominated before it ran and
was competing with P3 for the same exploration budget.
