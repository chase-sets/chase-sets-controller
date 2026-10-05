# Capability matrix and recalibration

Load only when refreshing measurements, adjudicating placement, investigating routing drift, or changing the matrix structure.

## Contents

- Capability matrix
- Recalibration
- September 23 benchmark rebalance
- September 28 benchmark rebalance
- September 29 Sol 6.1 snapshot

## Registry-bound lifecycle

The routing policy is a generation-stamped row/slot document. A slot names a
family, effort, and placement; dispatch resolves the family through the model
registry's current identity and account-admission lists. Current and historical
sets are separate: historical rows remain evidence-only, while a current swap
creates a new exact model/effort matrix configuration with empty evidence. A
stale or malformed registry uses only a validated, flagged last-known-good copy;
there is no guessed model, effort, price, or predecessor measurement transfer.

## September 29 Sol 6.1 snapshot

Todd's 2026-09-29 ruling makes version successors a clean in-place swap first
(`solVersionReplacement`); recalibration follows as a separate decision.
`benchmarkRebalance20260929` records AA Intelligence Index v4.3.2 values read
from the public model-page data for Sol 6.1 low through max, with Sol 6, Astra,
Opus 5.5 and Sonnet 5.5 comparators. Every value was flagged measured, not
estimated. It changes no placement: Sol 6.1 inherits exactly the Sol 6 rows as
`provisional`, and Sol quotas restart at n=0.

The snapshot shows Sol 6.1 ahead of Sol 6 at every effort and cheaper per task
at high and above. On index and Terminal-Bench 4.0, Sol 6.1 xhigh matches Astra
high at about a quarter of the API cost. Sol 6.1 high is cheaper but slightly
lower than Opus 5.5 medium (50.2 < 51.2 index; 51.5 < 52.5 TB4). Claude keeps
a GDPval lead, so prose and knowledge-work rows are not Sol candidates on this
evidence. Any row expansion needs a Todd ruling; these
values are priors, not M or B cells, and API cost per task is not pool quota
burn.

## September 28 benchmark rebalance

Todd's 2026-09-28 ruling, "Sonnet 5.5 is more capable then 5 it should be
recalibrated based on the benchmarks," authorizes the v4.19 rows 3/13 high
challenger quota, not new row defaults. `benchmarkRebalance20260928` is the
authored AA Intelligence Index v4.3.2 snapshot supplied by Todd, fetched that
day from the model/comparator pages, with official Sonnet pricing. Medium is
roughly Sol 6 medium / Opus 5.5 low class, replacing the old Sonnet capability
caveats; its named-latency/capacity placement remains `override-Todd`. High
contests Opus medium every third otherwise-Opus-medium Claude dispatch per
row, as `provisional`, until 20 determinate outcomes; block rate must be no
worse on that row once both have n>=20. Two consecutive mechanical failures
end the quota. Incumbents and all other exclusions stay unchanged.

All Claude benchmark rows are Default Fallback configurations, not proof of
pure-model results. This snapshot creates neither M cells nor B cells: B still
requires the exact configuration, governing benchmark and named baseline.
No generated block or historical evidence is changed. API task cost and
first-answer latency are not local accepted-artifact cost/completion time.
Sonnet and Opus share the Claude all-models weekly window, with unknown
relative quota burn. Native Claude USD stays authoritative; verified official
prices do not reprice Sonnet 5 history. The skill row table owns dispatch.

## September 23 benchmark rebalance

Todd's September 23 request to implement the evidence-backed recommendations
authorizes v4.17's changed rows as policy placements (`override-Todd`), recorded
at https://github.com/chase-sets/chase-sets/issues/4388#issuecomment-5797093035.
It does not manufacture local measurement, transfer old cells, relax protected
authorship, or authorize a host rotation. The matrix's authored
`benchmarkRebalance20260923` holds the dated public snapshot, sources and
provider-fallback limitations; it is not a generated or adjudicated cell.
The row table remains dispatch authority.

Provider fallback is part of the published configuration: never turn a fallback
to a retired model into production eligibility or a pure-model capability cell.
Response latency is not agent completion time; token price is not accepted
artifact cost. Subscription usage, not API list price, is the actual capacity
constraint; dollar estimates stay telemetry, never a spend gate.

Review each new configuration at the SKILL.md same-row checkpoint. Report
quality, severe escapes, repairs, resource use and completion latency. Missing
artifact joins or true elapsed time remain unknown. Benchmarks cannot certify
local service bars or justify a protected authorship change.

## Capability matrix (DRAFT — not yet authoritative)

`capability-matrix.json` in this directory is a draft replacement for the routing
table's prose: 14 capability dimensions across exact model/effort configs,
each cell scored as a **delta against that dimension's named baseline**
(0 = as good as that exact historical configuration, not a successor) with a
provenance letter — `M` measured here (with n) · `B` external benchmark · `V`
vendor claim · `null` unknown. **Unknown routes conservatively, never optimistically.**

At the 2026-09-22 successor cutover, filter `retiredModels` and configurations
with `historicalOnly` before considering any score or price. Preserve old
baselines and cells for comparison. Sol 6, Luna 6 and Opus 5.5 have independent
empty cells and no inherited generated blocks; the skill's row table governs
continuity and explicitly ruled benchmark placements. Do not pool
platform Responses traces with incumbent Claude-native traces, especially
Opus 5.5 and Sonnet 5.5 xhigh/max: the pool translator collapses those two upstream efforts.

The 2026-09-28 Sonnet 5.5 in-place replacement likewise starts with empty
cells and no inherited generated evidence. Sonnet 5 remains historical only;
its benchmarks and measurements below are not Sonnet 5.5 evidence. The
replacement's existing placements log `override-Todd`; its September 28
rows 3/13 high quota logs `provisional` without inheriting any evidence.

Two properties make it worth the move: the second-cheapest clearing config *is* the
fallback, permanently correct without maintenance, and a new model is one new column
rather than fifteen prose edits.

**Vetoes are categorical, never scalar.** A large negative can be outweighed by
cheapness; a veto cannot. Use it where running the config is worse than not doing
the task — Terra on review, deprecated Opus 4.8 everywhere, Fable on debugging.

**Pick the cheapest config clearing the dimension's bar — never the highest score.**
Highest-score routing sends everything to Fable/Opus max and inverts the rubric.

**Optimize on three axes: correctness FILTERS, cost CHOOSES, speed BREAKS TIES.**
A config below the bar is ineligible at any price — correctness is never traded
against cost. Among configs that clear it, take the cheapest. When something is
blocked behind the lane, prefer the faster config even at higher cost.

**Cost and speed are now measured, both harnesses.** `cost-harvest.ps1` →
`cost-ledger.jsonl` joins to canonical lifecycle rows by transcript. Claude reports
dollars directly; Codex reports tokens. The harvester therefore records two
Codex cost bases: billed-at-the-time USD for spend governance and
current-price-normalized USD for routing. **The matrix uses the normalized
figure, repricing every historical token trace at today's rates; otherwise a
price cut would compare identical work on different price eras.** Keep both
short/long price tables in step with the model table. OpenAI applies the
long-context tier to each request above 272K input tokens, but historical Codex
telemetry contains only a cumulative run total. Runs totaling at most 272K are
provably short; larger runs retain short/long bounds and use a labeled
long-tier upper bound for conservative routing rather than a false point
estimate. Codex emits no wall-clock, so its durations are file-span estimates.

**Log `-Transcript` on every dispatch** — the join key from a dispatch row to its
cost. Cost isn't knowable at dispatch time; it's reconciled afterwards, and
without the transcript name the spend can't be attributed to a row.

**Every generated cell is keyed by configuration (v4.13).** The ledger carries
no effort, so `matrix-refresh.ps1` resolves a run's effort from the dispatch
row joined on its transcript (`effortUsed` over `effort`), else from the
`<issue>-<model token>-<effort>-` transcript-name convention that
`cost-harvest.ps1` already trusts for Codex model identity. A receipt's author
effort is its `authorEffort` field (`log-event.ps1 -AuthorEffort`), else the
author's own dispatch rows up to the receipt's instant when they all agree.
Anything else is unresolved or ambiguous: it still counts for the model and the
row, but for no configuration, and the counts are reported in
`measuredAt.effortIdentity`. A config with no effort-resolved run carries no
`measured` block at all (`measuredAt.configsWithoutEffortEvidence`); the
per-model pooled figure that used to stand in for it lives only in
`measuredAt.byModel`. Before v4.13 every effort of one model reported the
model's whole sample as its own n, which is why an effort cell could never be
falsified and P4 closed unadjudicable.

**Never copy numbers into this file.** They go stale the moment a lane finishes —
this section used to carry hand-transcribed figures and every one had drifted
within a day. Current cost, speed, n and block rates live in the matrix's
generated `measured` blocks and `measuredAt` stamp. To read them:

```bash
.orchestrator/cost-harvest.ps1 && .orchestrator/matrix-refresh.ps1
```

Durable findings (qualitative, so they don't rot — check the matrix for figures):
- **Sol has historically been a major spender and a slow config.** Its per-run
  and per-minute positions can differ, which is why speed is its own axis.
- **An early small-n Opus 5 cost rank reversed as production volume grew.**
  That is the durable lesson: a thin cost cell is not routing evidence. Read
  current generated fields, measure rather than infer from list price, and do
  not make a small-sample rank load-bearing.
- **A run is not a fixed unit of work.** Per-run and per-minute rankings can
  disagree; always say which denominator you mean and calculate the comparison
  from current generated fields.
- Row-level cost rankings belong in `measuredAt.byRow`, not in this prose.

## Recalibration

Recompute the Pareto frontier monthly and after any model/price/tokenizer/harness
change; keep 5–10% exploration budget for challenger configs. Replace benchmark
priors with measured per-workload success rates: pick the lowest-cost config whose
**lower confidence bound** clears the service level.

On a price change, force-reharvest available Codex transcripts so
`usdCurrent` is regenerated from their token traces, then refresh the matrix.
Do not compare billed historical USD across price eras, and do not overwrite
billed USD with the counterfactual routing price. Audit
`pricingContextTier`, `usdCurrentLower`, and `usdCurrentUpper`; a cumulative
run total above 272K cannot establish that any one request crossed the tier.

**Author block rates are generated, not transcribed** — read
`measuredAt.blockRateByRowConfig` (row x author configuration) in the matrix
after a refresh, and `blockRateByRow` only for a per-model question. **Use the
per-row cells, never the aggregate.** The aggregate is difficulty-confounded
and the stratification demonstrably reverses its conclusions:

> On aggregate Sol and Sonnet 5 look **tied**. On **row 4**, where both actually
> compete, Sol is materially better on its own row and the aggregate was hiding
> it. Routing row-4 work to a Claude lane for work-conservation costs a real
> double-digit penalty in block rate. That is a price, not a free swap — take
> the current spread from the matrix before trading on it.

Cost has the same trap, and it had no cell until v4.2: `byRow` pools every model
on a row, so on exactly the rows where a challenger is being judged against an
incumbent it averages the two together. `byRowModel` (v4.2) split by model but
still pooled every effort of that model, so historical `gpt-5.6-sol/high` and `gpt-5.6-sol/xhigh` shared
one cell. **Read `measuredAt.byRowConfig`** for any per-config cost claim;
`byRow` answers "what does this row cost" and `byRowModel` "what does this
model cost on this row", never "what does this configuration cost on this
row", which is how every quota threshold is written.

Investigate row 6 and row 3 at each recalibration rather than preserving their
rank or status here. Current quality and cost evidence lives in
`blockRateByRowConfig` and `byRowConfig`; alternatives remain unchanged until
that evidence clears the routing bar.

Three sampling bugs the generated version exposed, all the same family — a
vocabulary that drifted while the numbers were maintained by hand:

1. **Four spellings of `Sonnet 5`** split one config's evidence into four
   under-powered samples. An early repair guessed aliases into one bucket; v4.0
   replaced that with exact-version enforcement and excluded ambiguous history,
   because alias mapping can silently transfer evidence to a successor.

   **v4.2 narrows that exclusion, which had over-corrected.** A spelling that
   already names the version (`sonnet-5`, `Sonnet 5`) is the same identity as
   its canonical form; folding it in carries the version through rather than
   inferring it, so it cannot leak evidence to a successor. **Bare families
   (`sonnet`, `fable`, `opus`) and deprecated versions stay excluded** — those
   are the actual guess v4.0 was defending against, and that defence is intact.

   Why it mattered: the over-wide exclusion was **not random**. Only Claude
   configs were ever mis-spelled, so it silently shrank one side of exactly the
   comparisons P1/P2/P5/P6 turn on, and it dropped enough rows to move a
   per-row rate onto the wrong side of a pre-registered threshold. Exclusions
   are now reported per spelling in `measuredAt.modelIdentityAudit`; a large,
   one-sided, silent exclusion is the failure mode, not exclusion itself.

   The emitter has rejected aliases outright since 2026-07-26
   (`log-event.ps1 Assert-ExactModelVersion`), so the contaminated window is
   closed and bounded — the repair is to history, and cannot regrow.
2. **`row` vs `routingRow`** silently dropped 57 rows from every cost join.
3. **17 distinct outcome values**, with everything not matching `BLOCK*` scored
   as a pass — `RETRY`, `skip`, `LOAD_SENSITIVE` and
   `TIMEOUT_ONLY_PENDING_DISCRIMINATOR` were counted as wins, biasing every
   block rate **downward**. Indeterminate outcomes are now excluded from the
   denominator rather than scored.

   **v4.2 adds the other half of that bug, which bit in the opposite
   direction.** A generic `^BLOCK` match also swallowed *mechanical* failures —
   harness faults, prompt blocks, failures reproducing on clean main — and
   scored them as author-quality defects, so a config was charged for whatever
   infrastructure it happened to draw. The rubric already says a mechanical
   failure is not evidence; that now holds in measurement too. Mechanical
   outcomes are excluded and counted in `measuredAt.mechanicalExcluded`.

   `verify-complete` was the source: `review-complete` outcomes have been
   constrained since the review contract, but verify outcomes were free text and
   drifted the same way replan states did. They are now canonicalized at write
   time to PASS / BLOCK / BLOCK_MECHANICAL / INDETERMINATE, preserving the
   caller's spelling in `outcomeRaw`, and genuinely ambiguous values are passed
   through unmapped rather than guessed into a bucket.

Hand-maintained numbers don't merely go stale — they hide the bugs that produced
them. Every rate the rubric quoted before 2026-07-24 was wrong in a direction
nobody could see.

**Correct the standing claim:** the rubric said Sol's block rate meant *"every
full-path first pass effectively budgets one review + one repair round."* On its
own row it is fewer than half of first passes, not every one.

---
*Evidence, benchmark tables, and version history: Claude memory
`chase-sets-model-routing-rubric`. This file stays rules-only (Todd directive).*
