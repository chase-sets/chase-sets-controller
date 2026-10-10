---
name: model-routing
description: Route a task to the cheapest registry-admitted family configuration and reasoning effort that clears its quality bar. Use when orchestrating chase-sets lanes, dispatching work to Codex/Claude lanes, choosing a model or effort, escalating a failed worker, or onboarding a newly released model.
---

# Model Routing (v4.23, 2026-10-06)

Version 4.23 implements Todd's #8915 benchmark rebalance from the October 6
exact-effort public snapshot. Every row now names its default, fallback and
governing benchmark; the row-2 Luna quota ends on the terminal-work prior,
not an invented local failure rate. Admitted defaults remain where a cheaper
configuration does not clear the row's benchmark comparator and constraints.
See `references/benchmark-rebalance-20261006.md` for all 15 decisions, expected
cost/latency effects and the separately owned selector-change ISS. Changed
placements log `override-Todd`, never `measured`. September snapshots remain
history; protected rules and closed watchdog routes are unchanged.

Version 4.22 replaces attempt-count artifact parking with
milestone-orchestrator's judged recovery ladder and fourth-attempt step-back
review (Todd, 4388/6022146271, #8903), and lets an exhausted review roster fall
back to the best reviewer that did not author or repair the exact revision,
with disclosure. It keeps v4.21's data-bound routing and capacity-forecast
behavior. Prior release notes are in milestone-orchestrator's
`references/rule-provenance-v2.24.md`.

### Data-bound selection

The routing-policy generation is the row authority: each row names a harness
slot (`codex.primary`, `codex.fallback`, `claude.primary`, or
`claude.fallback`) by family, effort, and placement. At dispatch the controller
resolves that family through `model-registry.json` `families.<family>.current`,
then requires the exact effort in `admittedEfforts` and a non-empty
`usableAccountsByEffort` set. A failed primary falls back by family slot, never
by a retired model string. Registry freshness, authority digest, and the
validated machine-local last-known-good flag are carried into dispatch,
ownership, watchdog, acknowledgement, and strict-review evidence. Historical
IDs remain readable for evidence but cannot be selected for new work; a current
swap therefore creates a new exact `<model>/<effort>` matrix configuration with
no predecessor measurements.
Sonnet means `claude-sonnet-5-5`: it takes every existing Sonnet row placement,
host arm, watchdog route (including row-10 high fallback), and restriction,
without expanding into new rows. Existing placements log `override-Todd`;
the September 28 high challenger quota below logs `provisional`. No trial
or shadow precedes eligibility. Rows 3/13 medium retain the named-constraint
rule below. Public benchmarks are policy priors, not M or automatically B
cells; B requires the exact configuration, governing benchmark and named
baseline. No Sonnet 5 score, veto, cost, benchmark, sample count, or verdict
transfers. `claude-sonnet-5` is historicalOnly and never selectable for new
writes; pinned in-flight workers may finish and historical receipts remain
readable without relabeling. Dead retired workers require fresh dispatch,
not automatic recovery. The registered host arm is now `sonnet55-high`;
this does not change the default host or authorize rotation.

Todd ruled on September 29 that new model versions are always more capable at
the same cost, or equally capable at lower cost, so a clean in-place swap goes
first and benchmark recalibration follows. Sol means `gpt-6.1-sol`: it takes
every Sol 6 row placement, effort, quota, fallback, watchdog route, vendor
fallback and the default Codex host arm (`sol61-high`), with placement
`provisional` as before. Sol quotas and n restart at zero; no Sol 6 score, veto,
cost, benchmark, sample count or verdict transfers. `gpt-6-sol` is
historicalOnly: pinned in-flight workers finish, receipts stay readable, dead
workers need a fresh dispatch, and host records cannot acquire or renew with it.
Prices match Sol 6 (2/10, long 4/15) with $0.10/M cached input; OpenAI lists
low through max efforts (no none/minimal). The live pool lists `gpt-6.1-sol`
on 3 of 4 Codex accounts and routes it only there. The authored
`benchmarkRebalance20260929` snapshot is historical policy-prior evidence.
The October 6 rebalance below is the later Todd ruling, not local measurement.

Only list actually reachable models as selectable; unreachable static models
are historical comparators, never dispatch candidates. The pool owner verified
native Claude Code 2.1.284 admission on 2026-09-28 at low, medium, high,
xhigh, and max: exit 0, result OK, modelUsage `claude-sonnet-5-5` only; the
pool's live Anthropic model list for all three Claude accounts includes it.
That is mechanical admission, not measured routing quality. Official prices
(checked 2026-09-28) are $2/M input, $10/M output, $0.20/M cache reads,
$2.50/M 5m cache writes and $4/M 1h writes, price band C unchanged. Source:
`https://platform.claude.com/docs/en/models/sonnet-5-5/overview`.
Native Claude reported USD remains authoritative; API estimates are telemetry,
never a spend gate or evidence about subscription quota burn.

Earlier v4.17 work (#8146, #8053, #8156, and #8157) remains historical
provenance. Retired configurations are historicalOnly, not selection
candidates; their benchmark cells and cost evidence remain read-only, while
new dispatches resolve exact current selectors from the registry.

Route to the cheapest configuration that clears the quality bar. Premium
configurations must cite a routing row.

The routing unit is a configuration: one exact model version at one exact
effort, such as `claude-opus-5-5/medium` or `gpt-6-astra/high`. Model and
effort are never chosen separately. A model sets the capability ceiling and
the per-step reliability
at a fixed price per token; effort buys more inference-time search and agentic
persistence from that model at a task-dependent token cost, and it closes the
gap to the ceiling only when the failure mode is under-search. A stronger
model at lower effort often beats a weaker one at higher effort, and more
steps from a less reliable model compound its errors, so the two axes are not
separable and no rule reasons about one without the other. Effort labels are
harness dials, not a shared scale: `high` on Sol and `high` on Opus 5.5 are
different quantities. Evidence, thresholds, quotas, and comparisons therefore
name configurations, never a bare model or a bare effort level.

Log every dispatch: task ID, exact reported model version, effort, `row:`,
`placement: measured|provisional|override-<who>`, transcript, and expected USD
(recorded, never binding). Log `authorEffort` on every review-complete and
verify-complete receipt (`log-event.ps1 -AuthorEffort`); a receipt's own
`effort` is the reviewer's dial, and without the author's the receipt scores a
model but not a configuration.
Never transfer a veto, score, cost, benchmark, or verdict across model versions
or between effort levels of one model. Exclude ambiguous family aliases and
unresolved efforts instead of guessing.

Load references only when needed:

- Historical experiment records, never for dispatch or placement:
  `references/experiments.md`.
- Matrix refresh, adjudication, routing-drift investigation, or recalibration:
  `references/capability-recalibration.md` and
  `capability-matrix.json`.

Normal dispatch does not load the matrix or experiment history.

## Successor cutover

After independently reviewed installation, new launches use `gpt-6.1-sol`,
`gpt-6-luna`, and `claude-opus-5-5`. GPT-5.6 Sol/Terra/Luna and Opus 5 are
historical only. There is no Terra successor: Sol 6.1 medium absorbs its routine
implementation role. Below, Sol/Luna/Opus mean the successors; dispatch pins
the exact selector. Existing pinned workers may finish. Do not relabel their
receipts, terminate workers, or rotate the host for migration. A dead retired
worker requires a fresh attributed dispatch, not an automatic version-changing
mechanical retry. Historical host identity records remain readable but cannot
be acquired or renewed with a retired selector.

Unchanged successor defaults are continuity placements. The September 23
benchmark rebalance below is Todd-authorized policy, not local measurement:
its new placements log `override-Todd`. Other successor placements remain
`provisional`; standing vendor substitutions and upper-tier policy placements
retain `override-Todd`. Never copy predecessor
scores, vetoes, costs, sample counts, or completed quotas. Matrix baselines
remain named historical comparators, not selectable defaults.

Availability is harness-specific. On 2026-09-22 native Claude initially refused
Opus 5.5 because its embedded client required >=2.1.280. After Todd-authorized
pool.14 deployment, the pool owner verified exact native Opus 5.5 high/xhigh
smokes: exit 0, OK, completed, canonical model, first-party provider. This
clears mechanical admission only, not routing quality or independent review.
Pool catalog or Responses availability alone is insufficient.
Coordinate default-config changes with the pool owner and the sole orchestrator;
never rewrite the curated catalog or transfer orchestration in this release.

## Models

| Model | $/M short input/output | $/M long input/output | Decision-changing constraints |
|---|---:|---:|---|
| GPT-6 Astra | 10 / 50 | 20 / 75 | Upper-tier Codex author; existing challenger evidence remains its own |
| GPT-6 Luna | 0.10 / 0.50 | 0.20 / 0.75 | Bounded triage/scoped-fix placement; under-60K routing envelope pending evidence, not a claimed context limit |
| GPT-6.1 Sol | 2 / 10 | 4 / 15 | Provisional executor (in-place Sol 6 replacement, 3 of 4 Codex accounts): medium routine implementation; high execution/debugging/recall review |
| Sonnet 5.5 | 2 / 10 | - | Conditional medium low-latency/capacity option; high challenger quota on rows 3/13, not a general default; no protected authorship |
| Opus 5.5 | 4 / 20 | - | Low bounded work, medium execution/precision review, high difficult execution/judgment; exact harness admission required |
| Fable 5.1 | 10 / 50 | - | Existing copy, design-system, novel UI/UX, architectural-core and named row-7 specialist under reserve; no general expansion |

Fable means Fable 5.1: pin `claude-fable-5-1` on every Fable dispatch. Todd
retired Fable 5 on 2026-09-07 with an in-place replacement: Fable 5.1 takes
every Fable row, effort default, reserve rule, and tier limit as written, with
no trial, shadow, or independent measurement before eligibility. Dispatches
log `placement: override-Todd` as a standing placement until the matrix
carries measured Fable 5.1 values. `claude-fable-5` is never selectable; its
scores, provider constraints, and measurements are historical comparators
only and do not transfer to 5.1. Fable 5.1 cache reads cost $0.25/M tokens;
model ID and prices:
`https://platform.claude.com/docs/en/models/fable-5-1/overview`.

Sol 6.1/Luna 6 list prices are telemetry estimates, not subscription spend or
capability evidence. Sources (checked 2026-09-22):
`https://developers.openai.com/api/docs/models/gpt-6.1-sol` (Sol 6.1 checked 2026-09-29; cached input $0.10/M),
`https://developers.openai.com/api/docs/models/gpt-6-luna`.
Requests over 272K input tokens use the long tier for the full request:
2x input and 1.5x output; cache reads 0.1x input except Sol 6.1 at
0.05x input, and writes remain 1.25x.
Opus 5.5 cache reads cost $0.20/M; writes $5/M (5m) or $8/M (1h).
Source: `https://platform.claude.com/docs/en/models/opus-5-5/overview`.
Predecessor effective-dated prices stay historical; never reprice an old
model's trace using a successor's rates.

Price changes alter cost selection and experiment value, never capability.
Do not promote a below-bar or unknown configuration because it became cheaper.
For routing comparisons, reprice all historical Codex token traces at current
rates; retain separately the billed-at-the-time USD needed for spend accounting.
Codex history exposes cumulative run tokens, not each request's context size.
A run totaling at most 272K input tokens is provably short-context. For a larger
run, retain short/long bounds and use the labeled long-tier upper bound as the
conservative routing estimate; never present cumulative tokens as proof that
one request crossed the tier.

Opus 4.8 is deprecated and off roster. Always pin `claude-opus-5-5`; a dispatch
reporting 4.8 is a mechanical defect whose output is discarded. Any Fable
identity mismatch is a same-config mechanical retry; Fable 5's
classifier-vocabulary and retention vetoes do not apply to 5.1 without
version-specific evidence.

Astra uses exact selector `gpt-6-astra`; supported task efforts are low, medium,
high, xhigh, and max (never minimal/none). High is the initial choice for
complex task rows 4-8 and 10-12; it enters a row through a challenger quota in
the row table or an explicit operator override. Availability does not
establish quality or change any default. Host selection uses
`start-host-trial.ps1 -Arm astra-high -Register` with a new `-Holder` at high
effort, one active host only, under the row-9 rotation rule. End transcript
labels at exact `gpt-6-astra` / `astra6`, or follow that selector with the
unambiguous double-hyphen delimiter (for example `gpt-6-astra--high`), so cost
attribution preserves the exact version. Sources:
https://developers.openai.com/api/docs/models/gpt-6-astra and
https://developers.openai.com/api/docs/pricing (checked 2026-09-04).

Caching rewards stable prefixes. Successor token use, delegation, latency,
and artifact cost must be measured anew; predecessor behavior does not transfer.

## Routing table

| # | Task | Default config | Qualified fallback config | Governing benchmark / constraint |
|---:|---|---|---|---|
| 1 | Classification, extraction, triage, prechecks, scoped summaries | `gpt-6-luna/low` provisional | `gpt-6-luna/medium` for harder bounded extraction within the existing row-1 envelope; beyond that envelope reclassify the task, never infer a new watchdog route | First-answer latency / index; medium latency not published, no coding expansion |
| 2 | Routine Codex implementation and scoped fixes | `gpt-6.1-sol/medium` provisional; Luna medium quota retired by #8915, not a measured demotion | `claude-opus-5-5/medium` under the same-effort vendor rule, override-Todd | Terminal-Bench 4: 47.98% versus Luna medium 2.53%; cheapest admitted routine executor |
| 3 | Routine Claude UI/admin using approved copy/components | `claude-opus-5-5/medium`; `claude-opus-5-5/low` only for bounded wiring with exact acceptance checks, high on evidenced under-search. Sonnet 5.5 medium conditional on named latency/capacity constraint (override-Todd); Sonnet 5.5 high takes every third Claude dispatch otherwise going to Opus 5.5 medium until n=20 determinate row-3 outcomes (provisional); threshold: block rate no worse than Opus 5.5 medium on row 3 once both have n>=20; end quota after two consecutive mechanical failures. Other new placements override-Todd; copy goes to row 14, design-system edits to row 15 | `gpt-6.1-sol/medium` cross-harness fallback | Terminal-Bench 4 / index; approved-component work only; Sonnet high remains a quota, not a default |
| 4 | Multi-file, terminal-heavy, migrations, infra, CI | `gpt-6.1-sol/high` provisional; Claude: `claude-opus-5-5/medium`, high for difficult execution (override-Todd). Retain Astra high every-third quota across rows 4/5/10, aggregate n=10, against historical Sol 5.6 high as below. Sol 6.1 medium takes the next row-4 dispatch after Astra, then every third once Astra quota ends, until n=20; threshold: no worse than Sol 6.1 high row 4 once both have n>=20 | `claude-opus-5-5/medium` for fresh cross-harness dispatch; `claude-opus-5-5/high` for ruled Sol-high continuation | Terminal-Bench 4: Sol high 51.52%; medium 47.98% does not clear that comparator |
| 5 | Multi-hour checklist/campaign/drain | `gpt-6.1-sol/high` provisional; Claude: `claude-opus-5-5/high`, `claude-opus-5-5/medium` for a fully specified checkable campaign (override-Todd). Retained Astra quota as row 4; Sol 6.1 xhigh only on evidenced need | `claude-opus-5-5/high` under the same-effort vendor rule | Terminal-Bench 4 / horizon; index is not proof of long-running artifact completion |
| 6 | Browser/computer use | `claude-opus-5-5/high` provisional after native tool-contract smoke; `gpt-6-astra/high` on Codex-native fit | `gpt-6.1-sol/high` | Computer-use benchmark at exact effort not published in snapshot; native smoke governs, index is secondary |
| 7 | Core, deep cross-context, invariants, money/contracts | Core: `gpt-6-astra/high` / `claude-fable-5-1/high` under reserve, override-Todd. Other work: `gpt-6.1-sol/high` provisional; Fable admitted for named money/contract/event slices. No new Opus primary authorship; old Opus P2 failure is historical, not a successor veto | `claude-fable-5-1/high` for Astra core under reserve; `gpt-6-astra/high` when reserve refuses core; `gpt-6.1-sol/high` only for non-core slices | AA-LCR / index; protected upper-tier authorship precedes all cost comparisons |
| 8 | Decomposition audits, irreversible judgment, final judge | `claude-opus-5-5/high` provisional; authoring core decisions remains row 7 | `gpt-6.1-sol/high` admitted independent cross-harness fallback, not claimed GDPval parity | GDPval / index: Opus high 1706.88 / 53.58; cheaper configurations do not match |
| 9 | Orchestrator host | Keep the operator-selected host. Codex-native: `gpt-6.1-sol/high` provisional; Claude-native: `claude-opus-5-5/high` override-Todd, not Sonnet | Registered `gpt-6-astra/high` arm, only on Todd's request; no automatic rotation or cross-provider hosting without separately reviewed lease admission | Operator authority first; Terminal-Bench 4 / GDPval are priors, never rotation authority; milestone-orchestrator section 2 |
| 10 | Debugging/root cause | `gpt-6.1-sol/high` provisional; retained Astra quota as row 4; Claude: `claude-opus-5-5/medium`, high for difficult or persistent reasoning failures (override-Todd); never Fable | `claude-opus-5-5/medium` for fresh cross-harness dispatch; `claude-opus-5-5/high` for ruled Sol-high continuation | Terminal-Bench 4: cheapest default matching the incumbent terminal prior; never Fable |
| 11 | High-recall money/contracts/infra review | `gpt-6.1-sol/high` provisional; never Fable | `claude-opus-5-5/high`; `gpt-6-astra/high` independent reviewer (override-Todd), subject to full-history preference and exhausted-roster rule below | Omniscience / index, GDPval cross-check; benchmark scores do not certify review recall |
| 12 | Precision-facing review | `claude-opus-5-5/medium` override-Todd; `claude-opus-5-5/high` for ambiguous/high-risk review. Never Luna; use row 11 for high-recall risk | `gpt-6.1-sol/high` independent fallback; `gpt-6-astra/high` independent reviewer (override-Todd) | GDPval / index: medium 1586.25 / 51.24; review-history constraints precede cost |
| 13 | Internal technical documentation/factual notes | `gpt-6.1-sol/medium`; Claude: `claude-opus-5-5/low` for factual notes, `claude-opus-5-5/medium` for multi-source synthesis (override-Todd). Sonnet 5.5 medium conditional on named latency/capacity constraint (override-Todd); Sonnet 5.5 high takes every third Claude dispatch otherwise going to Opus 5.5 medium until n=20 determinate row-13 outcomes (provisional); threshold: block rate no worse than Opus 5.5 medium on row 13 once both have n>=20; end quota after two consecutive mechanical failures. Extraction-only summaries use row 1; public prose goes to row 14 | `claude-opus-5-5/medium` for Sol medium; `gpt-6.1-sol/medium` for Opus low/medium under the existing closed routes | GDPval / AA-LCR; Sol low factual-note candidate needs separate selector admission, not an inferred watchdog route |
| 14 | Copywriting/localization/listings/public prose | `claude-fable-5-1/medium`; `claude-fable-5-1/high` flagship, override-Todd | `gpt-6-astra/high` when Codex-bound or reserve refuses | GDPval / index; protected copy authorship and Fable reserve govern, no benchmark certifies voice |
| 15 | Design-system changes and novel UI design | `claude-fable-5-1/high` override-Todd | `gpt-6-astra/high` when Codex-bound or reserve refuses | GDPval / index; exact-effort visual-design benchmark not published; protected design authorship governs |

### October 6 benchmark rebalance

`benchmarkRebalance20261006` is the current public prior; earlier dated snapshots
are history. The decision and effect table in
`references/benchmark-rebalance-20261006.md` re-derives all rows, including
unchanged defaults and constrained fallbacks. Benchmark comparators are not
the 85%/95%/99% local service bars. Missing evidence cannot clear a bar.
The row-2 Luna quota is retired, preserving its historical comparator and
receipts; it cannot be selected for a fresh coding task under that quota.
This is `override-Todd` selection policy, not a fabricated measured failure.
Fresh-dispatch alternatives above do not add watchdog continuations. Closed
routes, vendor fallbacks, host ownership and protected authorship stay intact.

### Capacity-balanced fresh dispatch

The amended interim Claude preference on rows 3/4/5/10/13 remains in force
until Todd activates the forecast. `dispatch-lane.ps1` reads the stateless
`capacity-forecast/v1` file under the routing state root. Only active, fresh,
well-formed input with known provider states can change a route. Shadow logs
`capacityShadowFlip` but never changes it; missing, malformed, stale or unknown
input keeps ordinary routing. No forecast last-known-good or relaunch balance.

Todd's ordered prefixes are Claude [13,10,4,5] and Codex [3,13,10,4]. The first
`balance.steps` rows (0..4), only when off-toward, use their own other-harness
policy slot including effort and placement. Ordinary explicit requests remain
eligible. Review/planning, row 0, relaunches, both integration paths and a
host-verified per-artifact `-ToddRouteOverride` binding are exempt before read.
Standing placement or Model/Effort arguments alone are not override authority.

Target refusal/fall-through skips. Complete branch-bound actual author, repair,
continuation and required unused-ladder history excludes exact model versions,
plus the proposed author and quota fallback, from row-11/12 review. Unknown
history or no admitted independent reviewer skips, never cleanses history.
The v3 dispatch row carries status, digest, active/shadow flip and skip reason;
historical v1/v2 rows remain readable. Active flips and proven same-config
continuations are separate `capacityFlipped` calibration cells; shadow stays
ordinary. Ambiguous or unbound joins never enter either cohort.

The watchdog stays closed-table and never reads the forecast. Additional
quota/session fallbacks, for flipped and unflipped authors alike, are row 13
Opus low -> Sol medium; rows 10/4 Opus medium -> Sol high; row 5 Opus high ->
Sol high, all `override-Todd`. Existing Sol-to-Opus entries are unchanged.

### September 23 benchmark rebalance

Todd requested implementation of the benchmark recommendations on September
23. The changed rows above are standing `override-Todd` placements after
independent exact-head installation, not fabricated `measured` promotions.
Read `references/capability-recalibration.md` for the dated evidence and
limitations. Keep every generated matrix block and historical identity intact.

Sonnet medium remains selectable on its existing rows 3/13 for a named
interactive-latency constraint or a demonstrated capacity advantage over the
row's qualified alternatives. Log the constraint and `override-Todd`; it is
not the default, a general repair rung, host, or automatic review fallback.
Pinned Sonnet 5 workers may finish without relabeling; they cannot relaunch.
Sonnet 5.5 same-configuration mechanical recovery preserves its attribution.

### September 28 benchmark rebalance

Todd ruled: "Sonnet 5.5 is more capable then 5 it should be recalibrated based
on the benchmarks." The authored `benchmarkRebalance20260928` snapshot records
AA Intelligence Index v4.3.2: medium improves 12.6 index points over Sonnet 5
and Terminal-Bench 4.0 rises from 2% to about 30%, roughly Sol 6 medium / Opus
5.5 low class. There is no inherited Sonnet-5 capability caveat. Opus remains
the cost-quality incumbent; Sonnet high is a new lower-cost Pareto point
against Opus medium, motivating the written rows 3/13 quota, not a promotion.
Sonnet xhigh/max are dominated on this policy comparison; max never starts.
Medium's first-answer latency edge remains a reason to name a constraint.
All Claude AA rows use Default Fallback: these are priors, not pure-model
B cells or local M evidence. Both models share the Claude all-models weekly
window; relative per-model quota burn is unknown. Keep the incumbents until
same-row evidence meets the written threshold; missing evidence stays
provisional. Todd may rebalance later. No Sonnet rows 4/5/7/8/11/12/14/15,
host default or automatic review fallback are added; row-10 high stays.
High quota mechanical recovery keeps `provisional` and the same configuration;
quota/session exhaustion returns `NO_QUALIFIED_FALLBACK` for host diagnosis,
not an inferred cross-model continuation. See the recalibration reference for limitations.

### Benchmark placement safeguards

An Opus low/medium placement requires admission for that exact effort on its
actual harness. If unavailable, use the row's admitted Sol alternative or
existing Opus high placement, without treating catalog presence as a smoke.
The new watchdog routes permit same-configuration mechanical recovery. On
rows 3/13 only, Sol 6.1 medium and Opus 5.5 medium have compiled quota/session
continuation in both directions as `override-Todd`; the four capacity routes
above also have closed quota fallbacks. Other routes retain
`NO_QUALIFIED_FALLBACK`, returning to the host for a
fresh attributed dispatch to an admitted row alternative after proven vacancy,
not an unrecorded watchdog substitution.
Prefer a fully independent reviewer: exclude every model on the artifact's
author and repair history, including quota/session continuation and repair
rungs; any platform
implementation must also exclude unused author-ladder rungs. On rows 11/12,
Astra high is the admitted independent reviewer (`override-Todd`, #8146) when
the row's Sol/Opus reviewers are excluded or unavailable. Exhausted roster
(4388/6022146271): When that exclusion leaves no admitted reviewer, the host
dispatches the best row-qualified admitted reviewer that did not author or
repair the exact revision under review. The host retains and inspects the
complete history, and the receipt discloses that reviewer's earlier
participation in the lineage. Never self-review the exact revision, and never
restore Sonnet to reach a reviewer count. Reviewer exhaustion never parks or
stalls the artifact. For `brief-repair-exhausts-independent-reviewers` the same
precedence holds: a fully independent reviewer first, then
milestone-orchestrator section 7's FINAL nonterminal proof route only when all
its predicates hold, then the exhausted-roster reviewer above. In-body brief
repairs count in brief repair history. Brief history does not automatically
exclude review of separately authored code: independently check code author/repair
history and platform author ladders. Effort/session changes never cleanse model history.
Protected authorship below still takes precedence over ordinary row fallbacks.

Review each new configuration at 20 determinate same-row outcomes, reporting
severe escapes, repair burden, accepted-artifact resource use and p50/p95
completion latency where available. A run is not an accepted artifact and
missing telemetry stays unknown. This checkpoint neither certifies the service
bar nor requires a new trial before the authorized defaults take effect.
An observed below-bar configuration is ineligible; use the qualified fallback
and record the rebalance. Never substitute cheapness for the quality bar.

### Upper-tier authorship requirements

Todd's 2026-09-12 ruling makes copywriting, design-system changes, and
architectural-core changes hard upper-tier requirements: only `claude-fable-5-1`
or `gpt-6-astra` at the row-7/14/15 configurations may author or repair them.
Sol and Opus must not write copy or change the design system or architectural
core; Sonnet, Terra, and Luna are also
ineligible authors. Routine scope does not waive this rule, and these
standing placements require no challenger quota. Log `placement: override-Todd`
for the new row-7/14/15 placements; this is a policy ruling, not measured evidence.

Copy includes creating, rewriting, translating, or polishing user-facing
words. Design-system changes include tokens, styles, shared components,
component behavior/APIs, patterns, and their supporting tests and documentation.
Using existing components and wiring approved copy verbatim in a consuming
feature is ordinary implementation; internal technical notes, code comments,
and review reports are not copywriting. Split mixed tasks so their copy and
design-system edits have an eligible author.

Architectural core means changes to aggregate/context boundaries, event
schemas, ordering, replay or projection semantics; shared authentication,
authorization, tenancy isolation, persistence or public cross-context contracts;
and execution authority such as orchestration, retries, idempotency,
concurrency, deployment or merge authorization. It includes the design/ADRs,
implementation, migrations, and supporting tests/docs that change these
responsibilities. Routine consumers of established contracts stay on their
ordinary rows. Classify by the responsibility being changed, not file count,
directory name, or apparent difficulty, and split mixed tasks accordingly.
A backend or review assignment does not grant core-authoring permission.

Reviewers may inspect and report findings under rows 11/12, but must return
all copy, design-system, and architectural-core edits, including mechanical
fixes, to an eligible author. This overrides direct-fix permission and any
lower-tier default, fallback, or escalation on other rows. Fable may design
and repair this work within its one-attempt reserve; a later repair can use
Astra high. If neither upper-tier configuration
is available, queue the affected work instead of falling back to a lower tier.

Keep row 1 on Luna 6 and row 2 on Sol 6.1 medium. Terra retirement consolidates
roles, not capability evidence: Luna 6 is not a blanket Terra replacement.
Its former row-2 quota is retired by #8915, not justified by price.

Opus 5.5 now serves both execution and judgment at the row's exact effort;
Sol remains the economical Codex executor. A reviewer applies mechanical fixes (pins, counts, generated
outputs, lint) directly outside the upper-tier authorship requirements and lets hosted CI validate them; semantic repairs
return to the author, and no reviewer validates its own patch. Fable is
eligible only for rows 7 (architectural core, money, contract, and event-invariant slices), 14,
and 15. Its only automatic fallback is the closed Astra-to-Fable route on
rows 7/14/15 under the existing reserve. Never use it as a shadow reviewer or
second opinion, or as an escalation rung outside those rows. A dispatch outside rows 7/14/15 requires Todd's
explicit per-artifact override and logs `placement: override-Todd` plus the
reason.

Harness binding is real: Claude lanes run Claude models and Codex lanes run
GPT-6. Soft specialization never justifies idling capacity,
but a cross-harness
swap must still clear the row's quality bar.

## Spend telemetry

Model usage is billed through usage subscriptions, not API pricing (Todd,
2026-09-07, #4388 decision registry). Spend is recorded, attributed, and
reported. It is never a gate.

- Record billed-at-the-time USD and current-price-normalized USD for every
  dispatch, artifact, lineage, UTC day, and month through `cost-harvest.ps1`
  and the cost ledger, keyed to the dispatch row, routing row, and
  configuration.
- Report in every digest and at the monthly recompute: daily and month-to-date
  billed USD, USD per delivered artifact by routing row and configuration, and
  the ten most expensive lineages with their attempt counts.
- Flag in the digest, notify-only, any UTC day above $1,500 or any month above
  $20,000 billed USD. These are attention markers for a retro, never a spend
  gate, breaker, park trigger, host rotation trigger, or Decision.
- No per-dispatch, per-artifact, lineage, daily, or monthly USD limit exists.
  Dispatch notes carry expected USD as telemetry only. The fourth-attempt
  step-back review (review, repair, and planning rounds never count) and the
  two-block rule in milestone-orchestrator are the only artifact checkpoints;
  neither parks an artifact (4388/6022146271). The controller never files a
  cap-only Decision.

Use billed-at-the-time USD for reporting and current-price-normalized USD for
routing comparisons. Host rotation is only on Todd's request (row 9),
never on spend.

## Fable availability reserve

Treat provider availability as a gate before current-price cost selection.
Fable dispatches must log the row, `fableReason`, observed remaining quota/reset
window when available, and expected USD in the dispatch note.

- The same model may work on several tasks at once (v4.15, Todd 2026-09-19,
  4388/5743836385): concurrent Fable lanes are bounded only by ordinary lane
  capacity, heavy-verifier admission, and single-writer-per-branch.
- Allow one Fable attempt per artifact; a second requires Todd's explicit
  approval. Never spend Fable at multiple stages of the same artifact.
- Never use Fable for shadows, routine review, semantic pressure, planning
  outside architectural-core design, standalone debugging, repair outside the
  upper-tier authorship requirements, controller review, or non-UI implementation outside the
  row-7 slices named above.
- Above 50% quota remaining, rows 14/15 and the named row-7 slices are
  eligible normally. At 25–50%, admit copywriting, design-system changes,
  important/novel UI/UX, architectural-core work, or a row-7 slice
  whose brief names money, contract, or event-invariant scope. Below 25%,
  preserve the reserve and use Astra high for rows 14/15 unless Todd marks Fable urgent;
  architectural-core work uses Astra high; other row-7 slices fall back to Sol high.
- When quota telemetry is unavailable, apply the conservative middle quota
  tier.
- Prefer Fable medium for row 14 when it clears the bar. Keep row 15 on high.
  Fable max remains a tier-3 exception and never starts an artifact.

When the Fable reserve refuses architectural-core work or rows 14/15, Astra high is the standing
upper-tier substitute. When an Astra author is quota-blocked or refused, the
lane falls to Fable 5.1 at the same effort only on rows 7/14/15 under the
existing reserve, never rows 8/11/12. When a Sol author is quota-blocked or
refused, the closed table selects Opus 5.5 at the same effort. These moves
relaunch as `override-Todd` and continue the same partial (v4.15,
Todd 2026-09-19, 4388/5743533387).
Author lanes and watchdog relaunches keep the standing `override-Todd`
literal; a strict controller-review dispatch or receipt tuple (a
review-head-contract strict row) records a ruled reviewer substitution as
`override-todd`, the only override grammar the strict reducer admits (#8064).
Never substitute a below-bar model merely to keep a lane occupied.

## Challenger quotas and rebalance

The legacy trial/shadow process, per-trial budgets, and experiment ledger are
retired (v4.12, Todd 2026-09-07). Quota and successor dispatches still require
the `provisional` evidence label. A challenger is a
configuration, and a different effort on the incumbent's own model is a
challenger like any other. A challenger enters a
row only through a quota rule written in the row table above: the share of
dispatches it takes, the n at which the quota ends, and the threshold it must
meet, all written before any of its scores exist. A quota dispatch logs
`placement: provisional` with the row; the incumbent keeps the default until
the rebalance reads the cells. No challenger reuses the incumbent's evidence.
The remaining successor quota is the row-4 share above; its n starts at zero. Retain
Astra's own accumulated evidence. Its historical comparator is frozen `gpt-5.6-sol/high`
row 4: 107/227, not stale prose 0.42; compare same-row current-price `usdPerRun`
without substituting Sol 6.1 prices. Luna's comparator is frozen
historical `gpt-5.6-terra/medium` row 2: 14/36, not stale prose 0.35. These are historical
thresholds, not successor measurements. End an affected quota after two
consecutive mechanical failures. Review each successor default at n=20
determinate exact-configuration outcomes per occupied row; missing same-row
evidence means remain provisional, not promote. Report severe escapes,
latency and artifact cost; small samples do not certify 95%/99% service bars.
The September 23 rows explicitly admit Opus 5.5 low/medium under Todd's
benchmark rebalance. Other configurations still need a written quota or an
explicit ruling; this does not expand protected authorship or host authority.

The cost contract is the generated
`measuredAt.byRowConfig[row, model, effort].usdPerRun`; `byRowModel` pools
every effort of one model and is not a configuration comparison. A run is not
an artifact, and no threshold cites USD per artifact until the ledger groups
runs into artifacts.

Rebalance runs every two weeks and on any model release: run the matrix
recompute, read `blockRateByRowConfig` by author configuration and row and
`usdPerRun` by row and configuration from the generated blocks, compare each
challenger against its written threshold and each incumbent against its row
bar, promote or demote by that comparison, and record the decision on the
#4388 decision registry. A cell whose author effort could not be resolved
(`measuredAt.effortIdentity`) is not configuration evidence. Between
rebalances the row table is the only routing authority. A B cell records only
a same-model, same-effort public result on the dimension's governing benchmark
with the baseline named; only M cells move a row without Todd's ruling. Host
choice is operator-controlled (row 9), never an automatic trial.

## Effort

Effort is chosen with the model, as one configuration, from the row table.
There is no separate effort dial and no score that sets one: the row names the
configuration, and a different effort is a different configuration that enters
a row only through a challenger quota or Todd's explicit per-artifact override
(`placement: override-Todd`).

Classify the task before routing it by asking which lever its likely failure
needs. The old effort score summed these signals into one number; they point at
four different levers.

- Ambiguity or taste (judgment, voice, design): the model lever. Route by row
  to the stronger model at the row's effort; effort does not buy judgment.
- Horizon or verifiability (many dependent stages, self-checkable intermediate
  results, invariants that must hold): the effort lever, on the same model.
- Risk (irreversible, money, contracts): the verification lever. Buy a judge,
  an independent review, or a deterministic checker, not effort in the author's
  lane.
- Context (input near the limit): the retrieval lever. Never raise effort or
  model to solve prompt length; retrieve or compact.
- Tooling (terminal-heavy, browser): a harness and row question.

Use the row's effort: Opus low/medium/high have different roles; Fable remains
medium for ordinary copy and high for its other admitted specialist work.
`max` is never a starting point. It requires a logged trigger: regulated or
irreversible ruling, two premium attempts disagreeing without a deterministic
verifier, or explicit promotion authority over money/infra/destruction.

## Price bands and effort ladders

Model size is not observable and is never a routing input; measured
per-configuration cells are.
Price bands are reporting labels, not capability classes: A $10/M input
(Astra/Fable), B $4/M (Opus 5.5), C $2/M (Sol 6.1/Sonnet 5.5), D $0.10/M (Luna 6).
Row-qualified fallback means the named configuration, not a same-price peer.

Routing ladders: Astra, Sol 6.1, Luna 6, Opus 5.5 and Sonnet 5.5 use low, medium,
high, xhigh, max; Fable uses low, medium, high, max. Low is the pool minimum;
neither none nor minimal is admitted. Sol ultra is pool-runnable but outside
this routing policy pending separate qualification. Opus 5.5 and Sonnet 5.5
xhigh are native Claude configurations; the pool Responses translator collapses xhigh/max to
upstream max. Do not mix those harness measurements or claim equal effort
labels across vendors. Retired ladders remain for history only.

## Escalation

Escalation is one configuration change chosen by the failure mode, never a
fixed ladder that buys effort first.

1. Run and validate externally.
2. Mechanical failure (harness fault, prompt block, reproduces on clean main):
   retry the same configuration once with the error.
3. Reasoning failure a verifier can name (wrong step, incomplete chain, missed
   invariant): raise effort one rung on the same model's ladder.
4. Knowledge or taste failure (wrong API, hallucinated fact, wrong pattern,
   weak voice or design): raise to the row's qualified fallback or specialist
   at the effort the row names for it. Effort does not buy knowledge.
5. Context failure (truncation, lost instructions, fill above 60%): retrieve
   or compact; no configuration change.
6. Two premium attempts disagree without a verifier: route one row-8 judge.

Stop after two configuration changes; any further attempt is governed only by
milestone-orchestrator's §7 recovery ladder, its fourth-attempt step-back
review and the two-block rule, never by spend.

Fable is not an escalation target outside rows 7/14/15. Use the qualified
Opus/Sol path or return the artifact to planning instead.

Tier-3 configurations (Sol xhigh/max, Fable max) are bounded exceptions:

- Never use tier 3 as an automatic repair rung.
- Require executed reproductions and implementation-shaped blockers.
- Allow at most one tier-3 attempt per artifact; a second requires a resolved
  decision issue.
- Two consecutive external blocks force planning/replan, not more intelligence.
- Log the expected USD and marginal gain over tier 2.

## Verification

No worker self-certifies. Use scoped tests/CI, deterministic checkers, external
authority evidence, an independent judge, or a person.

Quality bars:

- Internal draft: 85%.
- User-visible: 95%.
- Material operational action: 99%, independent verification, and rollback.
- Regulated or irreversible: human approval and audit trail.

## Gates

Before comparing candidates, require:

- Exact configuration availability: the effort is on that model's ladder and
  the chosen harness accepts it.
- Data-governance compatibility.
- Rate-limit headroom.
- Input plus reserved output within the context limit, with at least 15%
  reserve; prefer retrieval above 60% fill.
- Latency ceilings.
- No categorical veto for the task.
- Fable reserve eligibility when the candidate is Fable.

Correctness filters, availability reserves, cost chooses, and speed breaks ties.
A below-bar configuration is ineligible at any price. Unknown capability routes
conservatively.

## Maintenance routing

Onboard a new model by adding its exact selector to the table, its effort
ladder and one configuration per rung with empty cells to the matrix, and a
challenger quota to the row it should contest; then let the rebalance decide.
A configuration is two-dimensional, an exact model selector and an effort,
and its id is derived, never named: `<exact selector>/<effort>`, such as
`gpt-6-astra/high`, `gpt-6.1-sol/high`, or `claude-fable-5-1/high`.
`matrix-refresh.ps1` refuses a matrix whose config id is not exactly its
canonical model, a slash, and its effort, so an id can never drift from the
configuration it keys and a successor version can never inherit a
predecessor's key. Host-arm names in `start-host-trial.ps1` (`sol61-high`,
`astra-high`, milestone-orchestrator row 9) and transcript-name tokens
(`sol61--high`, `luna6--medium`, `astra6--high`, `sonnet55--high`; historical `sol6--high`) are not
configuration ids.
A new effort on an existing model is onboarded the same way: one
configuration, empty cells, a quota. `references/experiments.md` is a
historical record. Read
`references/capability-recalibration.md` before refreshing the matrix,
interpreting measured cells, or changing the frontier.

For a price change, update the skill table, the matrix's authored short/long
price fields, and the current and effective-dated tables in
`cost-harvest.ps1`. Force a harvest so historical token traces receive
current-price-normalized USD and auditable context-tier bounds, then refresh
the matrix. Never overwrite billed-at-the-time USD with a counterfactual price.
Evidence and history remain out of the normal dispatch path.
