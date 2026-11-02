# October 6 routing rebalance (#8915)

Authority: Todd, 2026-10-06, issue #8915 scopes 1-5. Fetch date for every source:
2026-10-06. Current snapshot: `benchmarkRebalance20261006` in
`../capability-matrix.json`; `benchmarkRebalance20260929` is unchanged history.
This is policy-prior adjudication, not local measurement or a B-cell promotion.
Changed selections log `override-Todd`; retained placements retain their labels.

## Decision Method

Filter protected scope, exact harness/effort admission, review independence,
reserve and operator ownership first. Within each already-qualified task tier,
compare the incumbent's governing public benchmark, then choose the cheapest
clearing admitted configuration. A benchmark score is not a local 85%/95%/99%
success probability. An admitted fallback is a constrained alternative, not a
claim that every fallback equals its default on every benchmark. Existing
cross-harness constraints and independent-review needs can make it necessary.
Unknown task-specific capability retains the conservative admitted default.

The comparison is between exact configurations on the same newly fetched
snapshot, not October timing for a candidate versus September timing for an
incumbent. Terminal-Bench 4 governs execution, GDPval and index govern judgment
priors, AA-LCR informs synthesis, and Omniscience informs high-recall review.
These are proxies, not UI taste, browser-tool-contract or review-recall evals.

The refreshed frontier supports keeping the principal defaults, not inventing
savings by lowering the quality comparator. Sol medium is materially below Sol
high on TB4 (47.98% vs 51.52%); Sol low is below routine implementation's medium
tier (30.81% vs 47.98%). Sonnet high is cheaper than Opus medium ($1.122 vs
$1.336 per index task) but lower on TB4/index (43.94%/46.75 vs 52.53%/51.24)
and slower per task (221.67s vs 204.54s). Opus high's GDPval 1706.88 exceeds
medium's 1586.25. None warrants an unconditional down-tier. Retained quotas
still obtain same-row evidence; they are not default or fallback promotions.

## Row Decisions

Names below abbreviate the exact selectors in SKILL.md. L = gpt-6-luna,
S = gpt-6.1-sol, A = gpt-6-astra, O = claude-opus-5-5, F = claude-fable-5-1.
Every default/fallback is explicit in SKILL.md, including harness and scope
exceptions. Dollar/time figures are estimated AA index-task proxies. Local
USD/run is unknown for these decisions; no public source measures an accepted
chase-sets artifact. Input tokens/run and subscription quota effects are also
unknown. A retained route has zero modeled selection effect, not a promise of
unchanged real completion time. Prices and generated local evidence stay intact.

| Row | Before -> after default | After fallback | Governing benchmark and decision | Expected USD/task and latency effect vs current default |
|---:|---|---|---|---|
| 1 | L low/medium -> same configurations, low default/medium bounded fallback | L medium only within the existing envelope; reclassify broader tasks | First-answer latency / index. Low: 2.53s, 21.53 index; cheapest bounded triage. Medium latency not published. | Low $0.004517 / 16.12s; selection delta $0 / 0s. Medium time delta unknown. |
| 2 | S medium with every-third scoped L medium quota -> S medium without Luna quota | O medium, same-effort vendor rule | TB4 47.98% vs L medium 2.53%; L high/max also cannot clear routine executor comparator. End quota by Todd policy, not measured local failures. | Default $0.213701 / 165.97s unchanged. Replaced quota slot: +$0.196224 (+1122.8%), output -3386.61 tokens (-29.6%); latency delta not published. At full old one-third quota utilization: +$0.065408 and -1128.87 output tokens per dispatch. Repair-adjusted USD/run and completion benefit unknown. |
| 3 | O medium (low bounded wiring) -> same | S medium cross-harness | TB4/index: O medium 52.53%/51.24. Sonnet high is not equivalent; keep rows 3/13 quota and conditional medium. | O medium $1.336009 / 204.54s; $0 / 0s selection delta. O low bounded: $0.551180 / 81.47s. |
| 4 | S high; Claude O medium -> same | O medium fresh; O high for S-high continuation | TB4: S high 51.52%, O medium 52.53%. S high is cheapest at its admitted heavy-execution comparator. Retain S-medium/A-high quotas. | S $0.319144 / 250.17s; O $1.336009 / 204.54s; each $0 / 0s selection delta. O is faster but costs +$1.016865/task; not a blanket cheaper replacement. |
| 5 | S high; Claude O high (medium fully specified) -> same | O high, same-effort vendor rule | TB4/horizon: S high 51.52%; no benchmark proves multi-hour completion. Lower effort remains scoped, not general. | S $0.319144 / 250.17s; O high $1.822505 / 282.08s; $0 / 0s selection delta. |
| 6 | O high; A high Codex-native fit -> same | S high | Exact-effort computer-use benchmark not published in this snapshot; official Opus tool-contract changes require native smoke. Index cannot authorize a tool swap. | O $1.822505 / 282.08s; A $1.725253 / 201.86s; $0 / 0s proxy selection delta; actual browser latency unknown. |
| 7 | Core A high/F high; other S high -> same | Core F high under reserve or A high; S high only non-core | AA-LCR/index secondary to immutable upper-tier rule. Cheaper Sol/Opus never become core authors. | A $1.725253 / 201.86s; F $3.912527 / 401.64s; S $0.319144 / 250.17s; $0 / 0s selection delta. |
| 8 | O high -> same | S high, independent admitted alternative | GDPval/index 1706.88/53.58 exceeds cheaper O medium and S high; keep difficult judgment tier, never infer 99% reliability. | $1.822505 / 282.08s; $0 / 0s selection delta. |
| 9 | Operator-selected host; S high or O high by harness -> same | Registered A high only when Todd requests | Operator ownership governs; TB4/GDPval are informational, not rotation triggers. | S $0.319144 / 250.17s; O $1.822505 / 282.08s; $0 / 0s selection delta; host-session cost unknown. |
| 10 | S high; Claude O medium -> same | O medium fresh; O high for S-high continuation | TB4 51.52% vs cheaper S medium 47.98%; persistent reasoning may need O high. Never Fable. | S $0.319144 / 250.17s; O $1.336009 / 204.54s; $0 / 0s selection delta. |
| 11 | S high -> same | O high / A high subject to review history | Omniscience/index: S high 41.45/50.24; S medium 39.95/47.78 cannot establish equal recall. GDPval favors O high but costs more. | $0.319144 / 250.17s; $0 / 0s selection delta. Review independence can require the more expensive fallback. |
| 12 | O medium (high ambiguous/high-risk) -> same | Independent S high / A high | GDPval/index 1586.25/51.24 vs S high 1486.41/50.24; S high remains constrained independent fallback, not precision parity. | Medium $1.336009 / 204.54s; high $1.822505 / 282.08s; $0 / 0s selection delta. |
| 13 | S medium; Claude O low factual/O medium synthesis -> same admitted defaults | O medium for S; S medium for O low/medium | GDPval/AA-LCR. S low is a cheaper factual-note candidate (1297/0.84 vs admitted O low 1235.17/0.81), but its new selector/override is not in the closed tables; submit ISS below, never silently route. | S medium $0.213701 / 165.97s; O low $0.551180 / 81.47s; O medium $1.336009 / 204.54s; $0 / 0s admitted selection delta. Candidate savings below are not realized. |
| 14 | F medium (high flagship) -> same | A high if Codex-bound/reserve refuses | GDPval/index: F medium 1549.16/48.92; F low not an admitted copy tier. Only F/A may author copy, independent of other models' higher benchmark results. | Medium $2.982597 / 308.97s; high $3.912527 / 401.64s; $0 / 0s selection delta. |
| 15 | F high -> same | A high if Codex-bound/reserve refuses | GDPval/index plus protected design tier. Exact-effort visual-design evaluation not published; no benchmark warrants down-tiering novel design. | $3.912527 / 401.64s; $0 / 0s proxy selection delta; design completion latency unknown. |

## Selector ISS

Prepared self-loop ISS, not a hand-edited platform selector and not a dispatch
authorization: **#8915 follow-up: qualify row-13 Sol low factual-note routing**.
Owner: orchestration platform self loop; host submits the ISS with this release.
Class: mechanical admission/selector gap, next step: exact-head implementation
and independent review of the narrowly scoped route below. No task parks on an
attempt count, unavailable tooling or reviewer exhaustion; current qualified
routes continue shipping in the meantime.

Proposal: factual internal notes only use `gpt-6.1-sol/low` with
`placement: override-Todd`; multi-source synthesis stays medium; extraction
stays row 1; public prose stays row 14. Versus S medium, public estimates are
$0.130752 vs $0.213701 (-$0.082949, -38.8%), 3976.70 vs 8069.84 output tokens
(-50.7%), 80.26s vs 165.97s/task (-51.6%), and 2.75s vs 5.42s first answer
(-49.2%). USD/run, input tokens/run and accepted-artifact savings remain unknown.

Required work: admit only row-13 Sol-low author/override in dispatch and
watchdog placement envelopes; keep the ruled Sol -> Opus same-effort vendor
fallback (low -> low) and existing Opus-low -> Sol-medium continuation. Preserve
all other closed entries and negative controls. The platform's own selector
generation belongs in its self loop, not this skill-only seat. Prove exact
configuration dispatch, mechanical recovery, quota fallback, protected-copy
refusal and no cross-row expansion. The skill default must change only with
that independently reviewed admission. Until then, it is a candidate, not a
default, a fallback, or an invented PASS. The author has not published this ISS.

## Sources And Limits

Fetched 2026-10-06, HTTP 200 for all URLs. The snapshot records SHA-256 of each
saved response, full precision rounded to six decimals, source slug and URL per
configuration. The page's own family/effort rows are used, not another page's
comparators. AA flags every included index as non-estimated. All Claude rows
explicitly use **Default Fallback**: neither pure-model B cells nor eligibility
for a retired provider fallback follows from those results. API USD and output
tokens/task are weighted across index evaluations. First-answer latency is not
completion time; index time/task is not local agent wall-clock time.

| Model | Artificial Analysis | Official vendor model overview |
|---|---|---|
| GPT-6 Luna | https://artificialanalysis.ai/models/gpt-6-luna | https://developers.openai.com/api/docs/models/gpt-6-luna |
| GPT-6.1 Sol | https://artificialanalysis.ai/models/gpt-6-1-sol | https://developers.openai.com/api/docs/models/gpt-6.1-sol |
| GPT-6 Astra | https://artificialanalysis.ai/models/gpt-6-astra | https://developers.openai.com/api/docs/models/gpt-6-astra |
| Claude Opus 5.5 | https://artificialanalysis.ai/models/claude-opus-5-5 | https://platform.claude.com/docs/en/models/opus-5-5/overview |
| Claude Sonnet 5.5 | https://artificialanalysis.ai/models/claude-sonnet-5-5 | https://platform.claude.com/docs/en/models/sonnet-5-5/overview |
| Claude Fable 5.1 | https://artificialanalysis.ai/models/claude-fable-5-1 | https://platform.claude.com/docs/en/models/fable-5-1/overview |

Official overviews confirm short-input/output/cache prices, not independent
per-effort benchmark quality or local USD/run. Exact-effort benchmark values
are **not published** in those official overviews. Luna medium AA time/task and
first-answer latency are **not published**; nulls are explicitly listed in
`notPublished`, never filled from another effort. All 28 nonhistorical matrix
configurations are covered, plus Fable low from its existing effort ladder.
Published Fable xhigh and Luna non-reasoning are outside the routing ladders
and are excluded, not newly admitted. Nothing refreshes generated matrix cells
or reprices historical traces in this release.
