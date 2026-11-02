---
name: model-routing
description: Route a task to the cheapest model and reasoning effort that clears its quality bar (GPT-6 Astra, Fable 5.1, Opus 5, Sonnet 5, GPT-5.6 Sol/Terra/Luna). Use when orchestrating chase-sets lanes, dispatching work to agents or Codex/Claude lanes, choosing a model for a task, setting reasoning effort, escalating a failed worker, or onboarding a newly released model.
---

# Model Routing (v4.14, 2026-09-12)

Route to the cheapest configuration that clears the quality bar. Premium
configurations must cite a routing row.

The routing unit is a configuration: one exact model version at one exact
effort, such as `claude-opus-5/medium` or `gpt-6-astra/high`. Model and
effort are never chosen separately. A model sets the capability ceiling and
the per-step reliability
at a fixed price per token; effort buys more inference-time search and agentic
persistence from that model at a task-dependent token cost, and it closes the
gap to the ceiling only when the failure mode is under-search. A stronger
model at lower effort often beats a weaker one at higher effort, and more
steps from a less reliable model compound its errors, so the two axes are not
separable and no rule reasons about one without the other. Effort labels are
harness dials, not a shared scale: `high` on Sol and `high` on Opus 5 are
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

## Models

| Model | $/M short input/output | $/M long input/output | Decision-changing constraints |
|---|---:|---:|---|
| GPT-6 Astra | 10 / 50 | 20 / 75 | Selectable Codex challenger; independent evidence required; configurations `gpt-6-astra/<effort>`; host arm `astra-high` in `start-host-trial.ps1` |
| GPT-5.6 Luna | 0.20 / 1.20 | 0.40 / 1.80 | Never use above roughly 60K input tokens or for recall-heavy/review-depth work |
| GPT-5.6 Terra | 2 / 12 | 4 / 18 | Never code review |
| Sonnet 5 | 2 / 10 | — | Default Claude implementation/internal documentation volume; no copywriting or design-system changes; tokenizer commonly emits more tokens |
| Opus 5 | 5 / 25 | — | Judgment, precision review, and computer-use specialist; cap subagents and read its `usdPerRun` by row at rebalance |
| GPT-5.6 Sol | 5 / 30 | 10 / 45 | Default Codex executor and debugging/review fallback; high review recall but noisy |
| Fable 5.1 | 10 / 50 | — | Specialist for copywriting, design-system changes, novel UI/UX, architectural-core design/implementation, and the row-7 money, contract, and event-invariant slices; never other non-UI implementation, code review, standalone debugging, judging, or hosting |

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

OpenAI changed standard short-context pricing on 2026-07-30: Luna fell 80%
from 1/6 and Terra fell 20% from 2.50/15. At current list rates Luna is 10%
of Terra and 4% of Sol; Terra is 40% of Sol. Source:
`https://developers.openai.com/api/docs/pricing`.
For GPT-5.6, a request with more than 272K input tokens uses the long-context
tier for that full request: 2x input and 1.5x output. Cache reads remain 0.1x
input and cache writes 1.25x input.

Price changes alter cost selection and experiment value, never capability.
Do not promote a below-bar or unknown configuration because it became cheaper.
For routing comparisons, reprice all historical Codex token traces at current
rates; retain separately the billed-at-the-time USD needed for spend accounting.
Codex history exposes cumulative run tokens, not each request's context size.
A run totaling at most 272K input tokens is provably short-context. For a larger
run, retain short/long bounds and use the labeled long-tier upper bound as the
conservative routing estimate; never present cumulative tokens as proof that
one request crossed the tier.

Opus 4.8 is deprecated and off roster. Always pin `claude-opus-5`; a dispatch
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

GPT-5.6 caching rewards stable prompt prefixes. Opus 5 tends to use more tokens
and subagents; a lower Opus 5 rung enters a row only through a quota, and its
value is measured per delivered artifact rather than per token.

## Routing table

| # | Task | Default config |
|---:|---|---|
| 1 | Classification, extraction, triage, prechecks, scoped summaries | Luna low/medium |
| 2 | Routine Codex implementation and scoped fixes | Terra medium; Luna medium takes every third scoped fix under 60K input until n=20, then the rebalance decides (threshold: block rate at or under Terra's row-2 0.35) |
| 3 | Routine Claude UI/admin implementation using existing approved copy and design-system components | Sonnet 5 medium; copy authorship routes to row 14 and design-system changes to row 15 |
| 4 | Multi-file, terminal-heavy, migration, infra, or CI implementation | Sol high; Astra high takes every third dispatch until rows 4, 5, and 10 together reach n=10 (threshold: block rate at or under Sol high's row-4 0.42 at no more than Sol high's same-row `usdPerRun` in `measuredAt.byRowConfig`); Sol medium takes the row-4 dispatch immediately following each Astra quota dispatch, and every third row-4 dispatch once that quota ends, until n=20 (threshold: block rate at or under Sol high's row-4 rate in `measuredAt.blockRateByRowConfig`; `usdPerRun` from `byRowConfig` is reported, not a threshold) |
| 5 | Multi-hour checklist/campaign/drain execution | Sol high; Astra high takes every third dispatch until rows 4, 5, and 10 together reach n=10 (threshold: block rate at or under Sol high's row-4 0.42 at no more than Sol high's same-row `usdPerRun` in `measuredAt.byRowConfig`); Sol xhigh only on measured need |
| 6 | Browser or computer use | Opus 5 high primary; Astra high on a Codex-native fit; Sol high fallback |
| 7 | Architectural core, deep cross-context implementation, event invariants, money/contracts | Architectural-core design, implementation, and repair: Astra high on Codex; Fable 5.1 high on Claude under its reserve. Other work: Sol high default; Fable 5.1 high admitted for money, contract, and event-invariant slices under the reserve; Opus 5 high withdrawn (P2 failed) |
| 8 | ADRs, decomposition audits, irreversible judgment, final judge | Opus 5 high provisional; Sol high fallback; authoring architectural-core decisions routes to row 7, with independent judgment/review retained here |
| 9 | Orchestrator host | Codex: Sol high default; Astra high selectable registered arm; Claude: Sonnet 5 high. Rotate daily or at the session limit, never on spend; registered Opus 5 host arm: the same |
| 10 | Debugging and root cause | Sol high; Astra high takes every third dispatch until rows 4, 5, and 10 together reach n=10 (threshold: block rate at or under Sol high's row-4 0.42 at no more than Sol high's same-row `usdPerRun` in `measuredAt.byRowConfig`); Claude lane: Sonnet 5 high; never Fable |
| 11 | High-recall code review for money/contracts/infra | Sol high; Opus 5 high fallback; never Fable |
| 12 | Precision-facing code review | Opus 5 high; Sonnet 5 medium fallback; never Terra |
| 13 | Internal technical documentation and factual operational notes | Sonnet 5 medium; user-facing copy, localization, listings, and marketing route to row 14 |
| 14 | Copywriting: product/UI text, localization, listings, marketing, and public prose | Fable 5.1 medium (high for flagship voice); Astra high for Codex-bound work or when the Fable reserve refuses |
| 15 | Design-system changes, including routine fixes, and novel UI design from a brief | Fable 5.1 high; Astra high for Codex-bound work or when the Fable reserve refuses |

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

Enforce the lower rows before buying capability the task does not need: keep
row 1 on Luna and row 2 on Terra. A row-2 task moves to Sol only when its scope
actually reclassifies it as row 4, not as an automatic escalation. Luna remains
unproven for implementation; its 10x list-price advantage over Terra is why it
holds the row-2 quota above, and the quota, not the price, is the only route to
placement.

Judge versus executor: use Opus 5 for provisional judgment/review and Sol for
agentic execution. A reviewer applies mechanical fixes (pins, counts, generated
outputs, lint) directly outside the upper-tier authorship requirements and lets hosted CI validate them; semantic repairs
return to the author, and no reviewer validates its own patch. Fable is
eligible only for rows 7 (architectural core, money, contract, and event-invariant slices), 14,
and 15. Never use it as an automatic fallback, escalation rung, shadow
reviewer, or second opinion. A dispatch outside rows 7/14/15 requires Todd's
explicit per-artifact override and logs `placement: override-Todd` plus the
reason.

Harness binding is real: Claude lanes run Claude models and Codex lanes run
GPT-5.6 or GPT-6 Astra. Soft specialization never justifies idling capacity,
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
  Dispatch notes carry expected USD as telemetry only. The
  four-implementation-attempt ceiling (review, repair, and planning rounds
  never count) and the two-block rule in milestone-orchestrator are the only
  artifact ceilings; a `REPLAN_REPLACED`
  lineage's terminal park follows milestone-orchestrator §12 and #7154 A1/B1 on
  attempts alone: one bounded continuation, then PARK at the one idempotent
  terminal receipt with no cap-only Decision. The controller never files a
  cap-only Decision.

Use billed-at-the-time USD for reporting and current-price-normalized USD for
routing comparisons. Host rotation is daily or at the session limit (row 9),
never on spend.

## Fable availability reserve

Treat provider availability as a gate before current-price cost selection.
Fable dispatches must log the row, `fableReason`, observed remaining quota/reset
window when available, and expected USD in the dispatch note.

- Allow only one concurrent Fable lane.
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
upper-tier substitute. If Astra is unavailable too, delay the work.
Never substitute a below-bar model merely to keep a lane occupied.

## Challenger quotas and rebalance

Trials, shadow pairs, provisional placements, per-trial budgets, and the
experiment ledger are retired (v4.12, Todd 2026-09-07). A challenger is a
configuration, and a different effort on the incumbent's own model is a
challenger like any other. A challenger enters a
row only through a quota rule written in the row table above: the share of
dispatches it takes, the n at which the quota ends, and the threshold it must
meet, all written before any of its scores exist. A quota dispatch logs
`placement: provisional` with the row; the incumbent keeps the default until
the rebalance reads the cells. No challenger reuses the incumbent's evidence.
Current quotas: Astra high takes every third dispatch on rows 4, 5, and 10
(aggregate n=10; block rate at or under Sol high's row-4 0.42 at no more than
Sol high's same-row `usdPerRun`; two consecutive mechanical harness failures
end the quota early), Sol medium takes the row-4 dispatch immediately
following each Astra quota dispatch and every third row-4 dispatch once that
quota ends (n=20; block rate at or under Sol high's row-4 rate; its
`usdPerRun` is reported, not a threshold, because an effort step down cannot
raise the price per token), and Luna medium takes every third scoped fix under
60K input on row 2 (n=20; block rate at or under Terra medium's row-2 0.35).
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
choice is a rotation rule (row 9), never a trial.

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

Premium effort defaults to high on Fable rows and provisional Opus 5 rows.
`max` is never a starting point. It requires a logged trigger: regulated or
irreversible ruling, two premium attempts disagreeing without a deterministic
verifier, or explicit promotion authority over money/infra/destruction.

## Price bands and effort ladders

Model size is not observable and is never a routing input; measured
per-configuration cells are. The only honest grouping of models is by list
price, and it is a reporting label: band A at $10/M input (Fable 5.1, Astra),
band B at $5/M (Opus 5, Sol), band C at $2/M (Sonnet 5, Terra), band D under
$1/M (Luna). Models in one band are not interchangeable: Sol and Opus 5 sit in
the same band and win different rows. "The row's qualified fallback or
specialist" in escalation means the configuration the row names, never "any
model in the next band".

Effort is standardized ordinally within a model, never across vendors. Each
model has an authored effort ladder in the matrix (`effortLadders`): GPT-5.6
Luna, Terra, and Sol run minimal, low, medium, high, xhigh, max; GPT-6 Astra
runs low, medium, high, xhigh, max; Sonnet 5, Opus 5, and Fable 5.1 run low,
medium, high, max. "One level" means the adjacent rung on that model's ladder.
A level absent from a model's ladder is unselectable, and a level shared by
name across models carries no shared meaning or evidence.

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
the four-implementation-attempt ceiling and the two-block rule, never by
spend.

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
`gpt-6-astra/high`, `gpt-5.6-sol/high`, or `claude-fable-5-1/high`.
`matrix-refresh.ps1` refuses a matrix whose config id is not exactly its
canonical model, a slash, and its effort, so an id can never drift from the
configuration it keys and a successor version can never inherit a
predecessor's key. Host-arm names in `start-host-trial.ps1` (`sol-high`,
`astra-high`, milestone-orchestrator row 9) and transcript-name tokens
(`sol-high`, `astra6--high`, the cost-harvest convention) are not
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
