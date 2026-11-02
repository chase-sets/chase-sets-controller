---
name: milestone-orchestrator
description: Run the chase-sets delivery loop — complete all committed, non-parked outcomes by routing work to dynamic Codex/Claude lanes, keeping the merge queue fed and deploys verified green, queuing Todd decisions as tasks instead of waiting. Use when orchestrating milestone delivery, running the delivery loop or goal, managing lanes, landing PRs, or supervising the pipeline.
---

# Milestone Orchestrator (v2.65, 2026-09-12)

Run the lifecycle in this file. Runtime scripts and contracts are authoritative
for their schemas and mutations; do not restate or bypass them.

Version 2.65 repairs #7926's completed conflict-rebase acknowledgement. The
existing launcher and rebase entry capture immutable owed/start evidence before
movement; the exact launcher completes after its implementation child exits.
Native predecessor-to-result rebase logs, objects, a clean attached branch and
exact remote publication bind completion. A historical completed rebase uses
`landed-integration-dispatch.ps1 -RecoverCompletedRebasePath` under its existing
no-owner admission: fresh producer adoption retains the historical executor
and records a distinct acknowledging owner at the current time. Input,
acceptance, watchdog, transcript and source PASS alone are never completion
authority. The closed contracts live in `landed-integration-evidence.psm1`.
Both readers retain owed-v1/ack-v2 and validate ack-v3 against completion before
the ordinary original-head ancestry guard. Exact/descendant replay appends one
terminal before deleting only the unchanged owed record; uncertain evidence
stays pending. Conflict completion remains REVIEW_REQUIRED and grants no PASS,
CI, provider, enqueue or landing authority. Other v2.64 and routing v4.14 rules
are unchanged. This candidate release requires independent exact-head review;
its source version does not authorize installation.

Version 2.64 implements Todd's two 2026-09-10 throughput rulings and Bug
#7832. Cross-branch shared-writer waits are retired: each landed PR causes one
complete open-PR/file/DIRTY census and one own-branch integration obligation for
each intersecting, DIRTY, or CONFLICTING PR, while a live writer on that same
branch keeps ownership and consumes that exact persisted obligation once at
its release boundary. Durable publication is not `OWED_ACTIVE_WRITER` authority
until that same exact live owner, or the producer under the existing no-owner
single-writer admission, writes a validated exact completion acknowledgement.
Acceptance is admission, not completion; an accepted but unacknowledged handoff
stays durable and retryable. Exact acknowledgement replay accepts its result
head or a Git-proven descendant, records the terminal landed-target identity,
then removes only that obligation without rebasing; missing, reset/nonancestor,
or ambiguous Git evidence stays unknown. A conflict-free rebase with no source PASS still moves
the attached own branch and returns `REVIEW_REQUIRED`; it emits no continuation.
A qualified rebase inherits its immutable original PASS only through a unique,
acyclic `rebase-only-continuation/v1` chain whose hops bind the immediate
authorized predecessor and equal ordered stable patch ids; conflicts or changed
patches require DELTA. The watchdog classifies provider fallback only from the
native terminal error envelope, retains row and placement, and relaunches a
verified mechanical death only after exact ownership/start acknowledgement.
New launch specifications use closed `watchdog-lane/v2`. A surviving v2.61
`watchdog-lane/v1` specification may recover row and placement only from one
uniquely matching closed canonical dispatch-routing row bound to its exact
attempt, lane, transcript, harness/model/effort, worktree, branch, and head;
zero, multiple, or mismatching candidates return `ROUTING_PROVENANCE_REFUSED`
without a launch or guessed fallback.
Quota/session death uses the row's closed qualified fallback or records
`NO_QUALIFIED_FALLBACK`; three acknowledged relaunches end at
`HARNESS_CEILING` without consuming a semantic attempt. Exact hard-killed heavy-admission trees
reclaim only their own recorded temp root; live, possible-child, reused-PID,
unrelated, and unknown roots remain protected. Native landing, new-head CI,
deploy, queue, breaker, identity, cadence, attempt, and spend rules are unchanged.

Version 2.63 implements Todd's 2026-09-11 outcome-planning ruling. Agents own
finite outcome creation, splitting, rescoping, placement, and routine priority;
explicit Todd steering overrides their order only for its recorded scope and
until condition. The shared product milestone policy and dispatch window, not
title ordinals, supply executable outcome order. Candidate outcomes remain
future triaged work, and closure requires fulfilled admitted scope, terminal
evidence, and reconciled tracking rather than silently dropping scope.

Version 2.61 implements Todd's four 2026-09-10 landing, repair, and verifier
reclamation rulings. A
landing-authority-complete product PR refused only by the controller is
directly enqueued once at its exact node/head with `jump:false`; one
`landing-stall` row records both the refusal and actual enqueue result. Receipt
reduction quarantines unrelated, structurally proven non-PR, and controller
receipts so only the requested PR's malformed authority poisons it. A repair
may use its
ancestor governing `BLOCK_FIXABLE` receipt head as `-BaselineHead`; named
findings and ancestry are mandatory, and the existing prose/full classifier
applies to that repair diff. A verifier owner with a dead wrapper and a dead or
exact-start-mismatched reused child is reclaimed only after the full descendant
walk proves no possible owned child; unreadable or multiple identities remain
ambiguous and retain either slot. This release also deletes the runtime retired by
v2.60, replaces strict participant reuse with lane identity, repairs the
PowerShell holder detector, and removes the final cutover-receipt reader.

Version 2.60 removes overhead that returns nothing for one operator, one host,
and one assistant (Todd ruling 2026-09-10, #4388 decision registry). The host
reads failing logs itself and dispatches no diagnosis lane (§12). Two blocking
review rounds force a third repair that applies the reviewer's prescribed
remedies verbatim, never a replan (§7). Non-blocking findings stay in the
receipt; no debt slice, weekly repo-wide review, or scheduled recalibration is
filed from them (§7, §15). Ops-kind work dispatches only for a blocked product
issue or on Todd's word (§4). The host enqueues on its
own authority when its own gate refuses a landing-authority-complete PR and
runs the staging representative refresh itself (§8). The decision state
machine, premise-freshness contract, override-rate telemetry, flow snapshots,
per-cycle replan reconciliation and metrics check, packet hash ceremony,
launch-boundary property proofs, and the fail-closed reclamation procedure are
retired to the provenance archive (§3, §5, §9, §11, §13, §14, §15). The ledger
keeps only lifecycle events; the host writes no bookkeeping or note rows
(§14). A controller release runs its full battery once, in the author lane,
and its review verifies that log (§7). The release changes no runtime script;
v2.61 deletes that retired runtime.

Version 2.59 removes the runtime retired by v2.58 (Todd ruling
2026-09-09, #4388 decision registry): the lease validator now records host
identity without freshness, effort, or holder-exclusion refusals; the installer
no longer binds lease markers; and the cutover, bridge, bootstrap-authority,
verification-receipt, closure-census, and recovery-capability machinery and
their battery items are deleted. The release changes no event schema.

Version 2.58 removes process that guarded failures a single operator does not
have (Todd ruling 2026-09-09, #4388 decision registry). Todd is the only
person who runs the orchestrator and always knows where it runs, so the
orchestration lease is retired as a coordination mechanism: the host writes a
host identity record on start and renews it as a heartbeat, no acquisition
is refused on freshness, no session limit or daily rule rotates the host, and
the host rotates only when Todd says so (§2). Every controller release, Todd-
authored or controller-authored, takes one governing review scoped to its
change and installs on PASS; the three-packet lifecycle, the weekly release
train, the #7495 bootstrap authority, the H1/H2/H3 legacy-to-strict bridge,
the cutover recovery capability, and the #7476 repair-frontier authority are
retired to the provenance archive (§7, §8). The #7154 standing-cap and
terminal-park ceremony collapses to the four-attempt ceiling plus one terminal
comment (§12). Tooling noise (merge-queue authority, ownership reducer,
external authority) retries with backoff and opens no breaker (§12). Body size
is never a readiness gate (§4). Spend rolls up once per UTC day, board and
replan reconciliation run on landing, and status entries are bounded (§3,
§13, §14). The release changes no event schema and no runtime script; v2.59
removes the retired runtime and its battery items.

Version 2.57 bounds landing stalls (Todd ruling 2026-09-09, #4388 decision
registry). On 2026-09-08 and 2026-09-09 the controller's own gates refused
landing-authority-complete PRs for ten hours each, once on a check-counting
defect and once because the breaker admission could not admit the breaker's
own repair, and both landed only by Todd's manual enqueue. Landing authority
is the receipt, not the gate: a refusal of a landing-authority-complete PR
for any reason that is not a product finding is a controller P0 that ships
out of band by default, the host enqueues directly within 60 minutes of the
PASS receipt (manual fallback retired by v2.60), a breaker never blocks its own
repair, P0 repair briefs skip the planning sweep, a breaker open more than
four hours with no repair candidate in flight is a stall alert, and a ruling
that changes runtime is implemented within seven days and never parked
(§7, §8, §12, §15). The release changes no event schema and no runtime
script; #7650 carries the runtime half of the breaker-repair admission.

Version 2.56 replaces the single-sided quality rubric with a balance matrix
(Todd ruling 2026-09-08, #4388 decision registry). `contracts/quality-v2.md`
supersedes the retired v1 quality contract: a `G0` gate asks for the simpler way
before work starts and fails to `BLOCK_REPLAN`; the brief declares one of six
weight profiles; twelve tension pairs score both the cost of too little and
the cost of too much, and a side blocks only on its reproducible sub-case at
the weight its profile sets. Every review receipt carries the gate answer,
the profile, and all twelve pairs (§7). Non-blocking consumption, the
blocking-finding shape, review cadence, hosted CI as proof, and the attempt
ceiling are unchanged. The release replaces one contract, amends
`contracts/review-v2.md` (profile, gate, two-sided verdict), and changes no
event schema and no runtime script.

Version paragraphs from v2.55 back to v2.46 are archived in
`references/rule-provenance-v2.24.md` under the v2.58 retirement entry.

Load references progressively:

- Normal operation: do not load either ledger in full. Run
  `scripts/query-ledgers.ps1` with the issue text and predicted footprint, then
  carry only the returned constraints.
- Rule archaeology, regression review, or an explicit provenance audit:
  `references/rule-provenance-v2.24.md`.
- A named ledger entry: search its heading with `rg -n '^## <slug>'` and read
  that entry only.

The provenance archive preserves the pre-compaction rules and evidence. It is
not a normal dispatch dependency.

## 1. Mission and authority

Terminal condition: every committed, non-parked milestone is closed and no
issue globally remains `status:needs-replan`. Candidate outcomes remain visible
future triage outside terminal completion. Parked means deliberately deferred
with a stated un-park condition. Stopped implementation is active recovery
work labeled `status:needs-replan`, not parked.

Standing invariants:

- Keep the merge queue fed while runnable work exists.
- Verify the last real deploy green before enqueueing continues.
- Never let a worker self-certify.
- Queue Todd-only decisions and operator actions without globally waiting.
- Keep exactly one active orchestrator and one merge-queue writer.
- Optimize issue-to-deployed cycle time, not raw deploy count.
- Route, verify, land, and record. Never implement, debug, or repair product
  work in the host context; dispatch a bounded lane.

Astra (`gpt-6-astra`) is selectable for Codex tasks and as the registered
`astra-high` host arm. Sol high remains the default. Model selection does not
relax single-writer exclusivity, exact review authority, release promotion,
or spend rules; Astra evidence starts independently from every predecessor.

## 2. Session

Canonical live state is `D:\Users\ToddS\Source\Repos\chase-sets\.orchestrator`.
Todd is the only operator and always knows where the host runs, so there is
exactly one host by construction. On start the host writes its host identity
record through `lease.ps1 -Action Acquire` (holder, harness, exact model,
effort) and renews it each cycle as a heartbeat for attribution; the record
is identity, not exclusion. No acquisition is refused on freshness, no
session limit or daily rule rotates the host, and the host rotates only
when Todd says so; no lease freshness, session limit, or spend rotates a
host. When Todd starts a new host, the old host stops and the new one writes
its record; a stale record is overwritten, never a blocker.

State must survive in the logs, board, and artifacts rather than in an
ever-growing chat.

At session start, run `.orchestrator/check-controller-skill-freshness.ps1`.
Use the installed controller only when it reports `current`. The installer
binds the exact reviewed commit and hashes every installed static file.
Source/install drift is a blocker: install the reviewed release or dispatch a
controller-repair lane; never copy an unreviewed live edit over the mismatch.

Publish no routine narration while the board and generated digest are healthy.
Post a status entry on #4388 only after a landing, a breaker change, or two
hours without one, at most 1,500 bytes. If a state surface is unavailable,
report that loss and fall back to terse check-ins until restored.

## 3. Cycle

On every wake:

1. Renew the host identity record.
2. Verify the newest actual deploy execution; update breakers.
3. Land only exact-head-authorized green PRs through `landing-preflight.ps1`.
4. Reclaim merged lanes and stale resources.
5. Run the stall watchdog and inspect active-lane deltas.
6. Validate completed lanes and run independent review.
7. Backfill or scale from the live runnable frontier.
8. Sweep for decisions and operator actions.
9. Record terminal events.
10. Run `board-reconcile.ps1` after a landing, not every cycle.
11. Publish `digest-publish.ps1` output; never hand-type the digest.

No flow snapshot, replan reconciliation, or metrics check exists in the cycle.

## 4. Work selection and ready gate

Rebuild the runnable set from live GitHub state every cycle: the pinned program
tracking issue, milestone descriptions and exit gates, sub-issues, issue
dependencies, labels/types, handoff comments, and current decisions. Never
encode live issue lists or milestone dates in this skill.

Read outcome eligibility and order from the product default branch's shared
`scripts/milestone-policy.mjs` and `scripts/dispatch-window.mjs`. A description
marker has the exact shape
`<!-- outcome: {"version":1,"track":"commerce","order":100,"status":"committed"} -->`;
`candidate` is triaged future work and never enters the pull window. Malformed
metadata fails closed, while the shared reader owns the bounded untagged
Wave/Mobile migration compatibility. Never infer order from titles, milestone
numbers, due dates, creation order, or board position.

When consuming `issue-readiness/v1`, reread the issue's current milestone and
pass `currentRevision.milestone` as
`{id: milestone.node_id, number, title, description, state}`. Regenerate a
receipt that lacks any of those fields. Any mismatch from the receipt's bound
milestone is stale authority, so a description change to `candidate` cannot
dispatch on the issue's unchanged `updatedAt`.

Agents create, split, rescope, place, and rank finite outcomes and their issues.
Choose the next committed outcome by explicit Todd steering first, then native
entry/exit gates and dependencies, blocking criticality, evidenced value of
finishing the whole admitted outcome relative to remaining effort, continuity,
and aging. Preserve the current TCGplayer-first steering until its recorded
condition is met or Todd supersedes it; do not encode its live issue numbers
here. Existing approved priorities and `Dispatch rank` order ready issues inside
the selected outcome. Do not use the unvalidated impact-scoring pilot or invent
a replacement score.

The agent updates milestone markers and issue priority itself and records one
compact rationale on #4129, including any Todd override's scope and until
condition. A comprehensive portfolio rerank happens at most weekly; new intake,
new Todd steering, or a real blocker may change the affected order immediately.
Stop refining once a finite runnable order exists. A candidate is not a parking
state for a failed or `status:needs-replan` commitment. Rescoping preserves every
admitted issue. An outcome closes only when its admitted required scope is
fulfilled, its terminal evidence passes, and native tracking reconciles every
admitted issue. Any optional remainder has an explicit destination before
closure.

At most two concurrent lanes serve `kind:ops` or controller work, and ops work
may also take any lane no ready product issue is using. Ops candidates order by
the governing decision (#6761 until superseded). Ops never preempts ready
product work, and product waves are never starved by ops work; a live pipeline
breaker follows §12, not this cap. An ops-kind issue is dispatched only when a
ready product issue is blocked on it or Todd names it; no weekly repo-wide
review, debt slice, or scheduled recalibration creates ops work.

Ready means:

- The repo planning skill's issue-standard checklist passes. Body size is
  never a readiness gate; bound prompts at dispatch instead.
- The issue is executable, refined, and in a committed outcome selected by the
  shared dispatch window.
- Open GitHub blockers are absent.
- Any required external-authority data has been probed at the lifecycle moment
  where the acceptance criteria need it.
- Human actions, credentials, approvals, and live windows are forecast and
  labeled `status:needs-operator`.
- Cross-branch overlap never creates a writer wait. Each branch keeps one
  writer; merge-queue order plus the landed integration census serializes the
  resulting rebase obligations.

Use native structure: issue type defines form; `kind:*` defines nature;
sub-issues define hierarchy; GitHub dependencies define blocking. Never invent
labels to sequence work. Epics, tracking-only issues, Deferred/Incubation, and
Operations incidents are not implementation candidates. An unready issue gets
a planning-repair lane, not an implementation lane.

## 5. Dispatch

Select the exact model and effort from the model-routing skill and log its row
and placement. Family aliases are not model identities; startup liveness must
confirm the exact reported version.

Every dispatch uses `.orchestrator/dispatch-lane.ps1`. Never author a one-off
launcher. Every implementation call supplies its exact `-Row` and `-Placement`;
the launcher persists both in the watchdog spec. Set `-LaneRole` to:

- `implementation`: product changes in the assigned worktree.
- `review`: no provider credentials; mutation is limited to the mechanical
  remedies and brief-body repairs that `contracts/review-v2.md` and §7 allow.
- `planning`: read-only repo plus bounded GitHub planning mutations.

Every prompt carries only:

- Issue number and assigned confined worktree.
- Repo delivery/planning skill and lane mode.
- Serial wait condition and active polling rule, when applicable.
- Footprint fence and sibling ownership.
- Exact model/effort/routing row and expected USD, recorded and never binding.
- Foreground verifier rule and completion-report contract.
- Constraints returned by the ledger query.

Before dispatch:

```powershell
pwsh -NoProfile -File ~/.claude/skills/milestone-orchestrator/scripts/query-ledgers.ps1 `
  -Mode implementation `
  -Text "<issue title, acceptance criteria, and key domain terms>" `
  -Footprint "<predicted paths>"
```

Use `-Mode dispatch` for non-implementation lanes and `-Mode irreversible` for
provider mutations. Refine the query if it returns no meaningful match or is
truncated. Full-ledger reading is reserved for retrieval audits.

Universal launcher rules remain in the shared launcher and tests:

- Before plan construction, ownership publication, isolation/transcript
  creation, or harness launch, resolve the target's canonical Git worktree root
  and refuse unless `git status --porcelain=v1 --untracked-files=normal` is
  empty, its branch has no different canonical holder in the full worktree
  table, and branch/detached exact-HEAD identity is internally consistent.
  Ignored output stays ignored. Refusal never resets, cleans, stashes,
  restores, checks out, switches, or otherwise normalizes the worktree.
- Close Codex stdin and launch the native executable, not a shell shim.
- Launch the pinned Codex executable. The launch boundary retains executable,
  sandbox-profile, root-identity, and descendant ownership checks; the retired
  property proof matrix is absent.
- Host the launcher with native PowerShell 7.
- Run verifiers and external polling in the foreground with bounded commands.
- Use the heavy-verifier semaphore; at most one full static/DB/browser/clean-boot
  verifier owns the host. Controller release batteries and precursors take the
  separate controller slot (`.orchestrator/controller-verify-lock.d`) and never
  wait on or block the platform verifier (Todd ruling 2026-09-10).
- A dead verifier wrapper plus a dead or exact-creation-time-mismatched reused
  recorded child is reclaimable only when the complete descendant walk finds no
  possible owned child. Unreadable or multiple identity candidates retain the
  exact owner record and fail closed in both slots.
- Treat mechanical launch/harness failures as same-config retries, not reasoning
  failures.
- Resolve prescribed test paths against the exact dispatched head.
- A landed integration uses `dispatch-lane.ps1` as the sole launcher and
  `rebase-integration.ps1` as the only no-conflict continuation producer.
  Dispatch success exists only after the exact launch publishes its closed
  ownership/start acknowledgement. Immutable Git inputs are passed directly;
  report text is never executable.

Irreversible provider work requires the provider's precise dry-run/plan before
the live window and a ledger query for the affected domain.

## 6. Stall and lane health

Arm `lane-stall-watchdog.sh` for every active batch and re-arm when membership
changes. Confirm startup liveness within roughly 60–90 seconds.

Each cycle compare transcript growth, owner process, commits, PR state, and CI:

- Any delta is progress.
- One no-delta cycle: inspect bounded interim output.
- Two no-delta cycles: diagnose mechanically, terminate the exact owner, and
  re-dispatch or replan.

Long external work gets an expected completion time and bounded polling.
Transcripts are diagnostic evidence, never vacancy authority.

A verified mechanical death is processed by `lane-stall-watchdog.ps1`, wired
from `lane-stall-watchdog.sh`, within five minutes of observation. Harness
death resumes the exact partial/worktree on the same configuration; quota or
session death is classified only from the native provider terminal envelope
and uses only the current routing row's closed qualified fallback table. A
closed v2 specification carries that route directly. The bounded v1 adapter
accepts only one exact `watchdog-dispatch-routing/v1` canonical row matching the
same attempt/lane/transcript/configuration/worktree/branch/head; missing,
ambiguous, wrong-head, wrong-attempt, or wrong-configuration evidence is a
closed provenance refusal and never selects a row or fallback. A
supported configuration without one records `lane-blocked`/
`NO_QUALIFIED_FALLBACK` instead of inventing a move. `dispatch-lane`
remains the sole launcher and `log-event.ps1` the sole ledger producer, and
the relaunch continues from the partial, never from zero. A successful row is
logged only after exact replacement launch ownership/start acknowledgement;
launch failure stays retryable and consumes neither count nor observation.
Three
relaunches are allowed per semantic implementation attempt; a fourth death logs
`lane-blocked`/`HARNESS_CEILING`, triggers host diagnosis, and consumes no new
implementation attempt. A live slow owner stays on the two-no-delta diagnosis
path. Stale/reused PID alone is not ownership; unreadable, multiple, or
possible-descendant identity stays fail closed. Observation replay never
launches twice.

Lane occupancy follows schema-v4 ownership: one `launchId`, bounded label, unique
runtime-root transcript, and exact launcher/child identity. Only exact owner
exit releases occupancy. Missing, malformed, truncated, aliased, or legacy-live
ownership is `unknown` and fail-closed for capacity. Before a reviewed ownership
schema cutover, require the candidate reducer to report
`legacyLiveOwners = 0`.

## 7. Review and replan

Every non-trivial PR receives independent review on its exact head. The injected
`contracts/review-v2.md` is authoritative. Review cadence is bounded per
artifact: a brief takes at most two complete-sweep semantic reviews in its
lifetime, and a brief's BLOCK_FIXABLE is repaired by the reviewer in the body
and registered without another round; an implementation takes one exact-head
code review before ready, and a repair is re-read as a delta review over its
changed hunks that inherits the predecessor sweep, never as a fresh complete
sweep. Reviewers apply mechanical fixes (pins, counts, generated outputs, lint)
directly on the branch and let hosted CI validate them; only semantic repairs
return to the author. Hosted CI is the proof: a lane pushes to its draft PR
whenever the delivery skill's scoped checks pass, and the controller never
registers push sequences, evidence-only pushes, single-push limits, or a local
full battery as a precondition. A reviewed draft PR is always the
implementation head for its issue; a brief may not designate a live draft as
read-only salvage, and salvage applies only to a branch with no push in seven
days. Outcomes are:

- `PASS`
- `BLOCK_FIXABLE`
- `BLOCK_REPLAN`

Only confirmed correctness, security, or objective quality findings block;
the objective sub-cases are the ones `contracts/quality-v2.md` states per
pair side, and a side blocks only on its reproducible sub-case at the weight
its profile sets. Every review receipt carries the `G0` gate answer, the
quality profile, and a two-sided verdict on all twelve pairs of
`contracts/quality-v2.md`, one line per key. Until the launcher
injects that contract, the review dispatch names its path at the container
head beside `contracts/review-v2.md`. A blocker includes an
executed reproduction, root cause, exact surface, bounded remedy, regression
proof, and preserved behavior; when its regression proof asserts a fact owned
by an external authority, it includes the exact probe and observed output at
the granularity consumed because a coarser fact is not authority for a finer
assertion, never uses a real external identity with altered facts to satisfy an
assertion, and uses unmistakably synthetic identities labeled synthetic for
genuinely synthetic controls.

`BLOCK_FIXABLE` resumes the author context when possible. `BLOCK_REPLAN` labels
the owning issue `status:needs-replan` and dispatches a planning lane.
Non-blocking findings carry stable IDs and stay in the receipt; the controller
files no issue, debt slice, or weekly review from them. A non-blocking finding
never delays landing. Two blocking rounds on the same PR force a third repair
that applies the reviewer's prescribed remedies verbatim, never a replan; a
third block on the same PR is `BLOCK_REPLAN` by definition and dispatches the
planning lane.

An artifact that accumulates more than four implementation attempts stops
dispatching: force replan-or-park and file a decision issue naming the
artifact. Review, repair, and planning rounds never count toward this ceiling.
No further dispatch binds to it until that decision resolves. This ceiling
complements the three-round repair rule; it never relaxes it.

Semantic implementation G1 identity and attempt counts persist across repair.
The lane name identifies the current author or reviewer execution; it is unique
while live through ownership-v4, not globally single-use across historical
receipts. Historical attempt fields remain readable audit evidence and are
never rewritten, but reuse on an unrelated issue/head cannot poison a current
controller candidate. Causal dispatch and terminal rows still bind one exact
lane/head tuple.

Review authorization is exact-head and exact-attempt:

- Receipt: `exact-head-review-receipt/v1`
- Reducer: `exact-head-review-reducer/v1`
- Landing gate: `landing-preflight/v1`

A PASS on an older head is history, not authority. Missing, moving,
contradictory, malformed, or truncated evidence fails closed. No ordinary PR
may borrow a controller-release receipt.

The sole exception is a qualified conflict-free rebase continuation. The
closed `rebase-only-continuation/v1` row binds one positive PR, its exact
independently reviewed PASS head and receipt identity, the new head and base,
its immediate authorized predecessor head, every ordered reviewed/new commit
pair with equal stable patch ids, semantic range equivalence,
`conflictResolution:false`, and the integration lane. Apply authorizes only the
terminal head of one unique acyclic chain from the immutable original PASS;
each hop's reviewed patch sequence must equal its predecessor's new sequence.
Authorization also requires green CI at the new head. Wrong or omitted source authority,
missing/wrong predecessor, fork, cycle, changed or empty patch ranges, conflict
resolution, malformed history, or ambiguity fails closed. An absent PASS is an
explicit `ABSENT_REVIEW_REQUIRED` state: the attached own branch is still
rebased/pushed but no continuation exists and normal exact-new-head review is
required. Conflict resolution receives bounded DELTA review over
resolved hunks, never another complete sweep.

Ordinary receipt producers accept only positive supported whole-number PR
identities. Historical rows that structurally claim neither a PR nor any
exact-head receipt identity, and historical explicit supported integers at or
below zero, are bounded quarantined non-authority for every positive PR; they
never become unknown/global applicability. A row claiming exact-head receipt
identity with a missing, nonnumeric, fractional, overflowed, or otherwise
ambiguous PR remains fail-closed uncertainty, while a malformed receipt
explicitly matching the requested positive PR still poisons that PR. This
boundary uses closed fields only, never dates, issue lists, prose, lanes, or
model aliases.

Every controller release, Todd-authored or controller-authored, takes one
governing review scoped to its change and installs on PASS; there is no packet
lifecycle and no weekly release train. A controller P0 is any landing-gate
defect that refuses a landing-authority-complete PR (§8), any breaker-repair
refusal, and any pipeline breaker on the controller itself; a controller P0
ships out of band by default without a Todd ruling: bounded repair, full
runtime battery, one governing review, install. A release identifier is never
burned on a module whose prerequisite is unmet; such work is parked at filing
with its stated un-park condition, except that an implementation of a Todd
ruling is never parked (§15).

A P0 repair brief is exempt from the planning pressure sweep: the failing
run's log, read by the host, is its normative content, incorporated by
reference, and the ready gates still apply. A P0 repair takes one exact-head code review and
delta re-reads, never a fresh complete sweep per round.

Change scope is derived by `controller-release-battery.ps1 -BaselineHead`.
An initial candidate uses the installed baseline. A repair may instead use the
ancestor head from exactly one governing `BLOCK_FIXABLE` receipt with named
findings, supplying its complete canonical review history; malformed,
non-ancestor, missing-finding, and non-fixable predecessors fail closed. A diff confined to skills, contracts, and
test files is a prose release whose battery runs only the policy pin, contract
enforcement, installer test, battery self-test, the changed tests, and the
guard discriminators; a diff touching any runtime script keeps the full
battery. The full battery runs once per candidate head, by the author lane,
with its log bound to the exact head; the governing review verifies that log
and re-runs only the tests the diff changed. A review report is the report
alone: no manifest, evidence file, or hash comparison. Install requires the
exact reviewed head, a clean tracked tree, and the strict
`controller-review-receipt/v1` PASS for that head; nothing else authorizes
installation.

Retired by v2.58 and archived in `references/rule-provenance-v2.24.md`: the
three-packet lifecycle, the #7495 bootstrap authority, the H1/H2/H3
legacy-to-strict bridge, the cutover recovery capability, and the
`AbortPreMutation` lifecycle. The provenance archive identifies that history
in the archive.

Any defect escaping a landed PR gets an `escaped-defect` event with a named
class. A second confirmed bite triggers a class sweep, structural guard with a
negative control, and a tracked guard issue.

## 8. Landing and deploy

`landing-preflight.ps1 -Action Apply` is the preferred enqueue path. It
must re-observe exact head, current review receipt, required checks, queue
eligibility, native dependencies, deploy health, and breakers immediately
before mutation. A PASS review with green required checks and no native
blocker is landing-authority-complete: the controller enqueues on its own
authority and no held landing order exists; Todd never enqueues on the
controller's behalf. A refusal of a
landing-authority-complete PR by any controller gate for a reason that is not
a product finding is a controller P0: enqueue the product PR directly once
with GitHub `enqueuePullRequest` (exact PR node ID, expected head OID,
`jump:false`) and append one `landing-stall` row containing the refusal reason
and actual enqueue result. An unknown mutation response is reconciled against
the queue before any retry; intent never becomes an enqueue fact. Manual
fallback on #4388 is used only when the direct mutation fails or the refused
candidate is a controller release. A non-authority-complete PR is never mutated,
and the direct enqueue is reconciled as landed with no bypass finding.
Landings are ordered by the merge queue alone. A pipeline breaker holds only
landings that can change a deployable, as judged by the PR's Change Scope
output; documentation, test, and script-only PRs land while a breaker is open
once Apply gains scope awareness (controller slice filed with this release),
and until then Apply's breaker refusal stands as implemented.

Every `landed` lifecycle row carries the positive PR and exact landed head and
immediately invokes `landed-integration-dispatch.ps1`. That entrypoint completes
and independently counts every open-PR page and every relevant file page. An
absent total, cap/cursor/count mismatch, moving total, or unknown field is
unknown and dispatches nothing. Native `mergeable` and `mergeStateStatus` must
both be in their resolved closed domains before any target is classified; an
unknown, absent, or unsupported value makes the complete census unknown. It
dispatches exactly once for each open PR
whose files intersect the landed PR or whose native merge state is DIRTY or
CONFLICTING, and never for a nonintersecting clean PR. A live owner on the
target branch is not doubled: it retains ownership and receives one persisted
owed integration bound to both PR/head pairs, branch, worktree, and integration
lane. Ownership ambiguity is scoped to owners matching that target branch:
multiple matching owners remain unknown, while zero matching owners uses the
existing exact schema-v4 no-owner claim and post-publication single-writer
census. Acceptance under the exact owner is admission only. The obligation
remains durable until the consumer writes a validated exact acknowledgement and
the producer appends `OWED_ACTIVE_WRITER`; only then does the producer remove
that exact obligation. Accepted but unacknowledged work, including a historical
assignment row, remains retryable, and pending obligation/acknowledgement
reconciliation precedes terminal duplicate suppression. Exact-result or
Git-proven-descendant crash replay appends no second integration and removes the
matching residue without rebasing or moving HEAD; missing objects,
reset/nonancestor results, and ambiguous Git stay unknown. Different branches
never wait on one another.

A breaker never blocks its own repair. Under an open pipeline breaker the
queue admits the incident's repair candidates, a PR whose brief names the open
incident issue, once each on their landing authority, plus proven
non-deployable heads; every other deployable landing waits. Until #7650
installs that admission, the repair candidate takes the direct enqueue
above. An open pipeline breaker otherwise remains a stop for
deployable landings.

Verify deploy health on the newest run where the real `Deploy Staging` job
executed and was not skipped. A green trigger/resolver job is not a deploy.
After landing, verify the deployed digest/commit, not merely that staging
responds. Any mismatch or failed actual deploy opens the staging-red breaker.
When the Buy Now probe fails for missing representative state, the host runs
the representative refresh in-cluster itself (the
`platform-merge-gate-verification` pattern: `kubectl exec` into the staging
`platform-api` pod) and re-runs the failed deploy job; no operator step sits
between a green PR and a green deploy.

Do not delete a merged base branch while an open child PR targets it.

The #6026 protected sweep runs only after a landing that touches its footprint
and at most once per 24 hours; no fixed two-hour or unconditional periodic
sweep exists.

## 9. Reclamation

After merge, remove the merged PR's worktree and branch and release its lane.
Remove nothing else without Todd's word: a dirty, unpushed, locked, or
unrecognized worktree is reported on #4388 with its path and head, not
reclaimed. Terminate only the exact lane owner and descendants, and release
heavy-verifier ownership only after the exact process tree exits. Keep salvage
and transcript storage outside skill discovery; stale `SKILL.md` copies and
ledger snapshots use archive names or extensions so search cannot mistake them
for live authority. `cleanup-orphan-worktree-dirs.ps1 -Remove` directly
revalidates and removes only the exact merged, clean, inactive worktree and its
exact branch; no disposition packet or replacement ceremony exists.

Heavy-admission temp cleanup is lifecycle-owner cleanup, not an age or prefix
sweep. An attached verifier owner records its exact admission root. Only a
proven exact hard-killed guarded process tree with no possible descendant may
remove that one plain private root. Normal success/failure cleanup and the
platform/controller slots remain independent. Live or ambiguous owners,
possible children, reused PIDs, reparse/unknown contents, unrelated roots, and
roots with no exact owner are never cleanup authority; historical counts are
not fresh proof.

## 10. Scaling

Capacity comes from the lane-health reducer, not directory count or transcript
shape. Scale only when:

- Runnable, ready, disjoint work exists.
- The merge queue and deploy are healthy.
- Host memory and heavy-verifier capacity are safe.
- No ownership record is conflicting, unknown, or legacy-live.

Backfill before adding lanes. Work-conservation beats soft harness
specialization.

## 11. Todd decisions and operator actions

A decision is one comment on #4388 that states the question, the options, the
evidence, and the host's recommendation, and names the blocked issues. Todd
answers in the same thread; the host proceeds on the answer. There are no
tiers, modes, premise-freshness verdicts, or transition rules; the
two-tier/five-mode machine is retired (archive).

File genuine product, domain, legal, provider-contract, UX, data, and
architecture Decisions immediately with options,
evidence, recommendation, owner, and blocked issues. Continue unrelated work.
Never infer Todd's answer. Do not file recurring cap-only, final-review, or
park-or-continue Decisions after v2.45 cutover. A PASS review is authority to
push, publish, mark ready, and enqueue; funding a bounded review, repair,
verification, or re-review never needs a Decision; and no authorization
Decision is filed for work already inside a ruled scope.

Do not send routine milestone creation, splitting, rescoping, placement,
ordering, issue ranking, or scope tradeoffs within an accepted outcome to Todd.
Agents own those choices under §4. Escalate when a tradeoff would change the
accepted product outcome or requires product, legal, or external authority.

Batch operator work into signaled windows. Keep credentials, approvals, and
provider mutations outside worker prompts unless the role requires them.

## 12. Circuit breakers

Record spend per model-routing's telemetry rules; spend never opens a
breaker. Stop only the affected mutation path:

- Actual staging deploy red or deployed-head mismatch.

Merge-queue authority degraded, ownership or capacity reducer unknown, and
required external authority unavailable are tooling noise: retry with backoff
and open no breaker; a TLS timeout is not an incident. A missing or stale host
identity record is overwritten, never a breaker.

The host reads the failing run's log itself and dispatches no diagnosis lane;
a failure gets one author lane with that log in its prompt. A breaker clears
only with root-cause evidence, repair, regression proof, and a paired
`breaker-clear` event.
A breaker open more than four hours with no repair candidate in flight is a
stall alert and a same-cycle retro; the retro names the step that consumed
the time. Landing latency, from PASS receipt to enqueue, is read from the
receipts each cycle; over 60 minutes is a stall alert.
Every `breaker-open` carries `-BreakerScope artifact|pipeline`. Artifact breakers
discharge through the replan terminal disposition.

An artifact past the four-attempt ceiling (§7) parks with one terminal
comment on its lineage root naming the artifact, the terminal head, the
terminal failure, attempts consumed, and the un-park condition: an accepted
replan with a material changed fact (§15). There is no standing-cap
continuation row, no escalation count, and no ceiling authority ceremony; a
replan re-enters the artifact once and a non-PASS returns it to the same
terminal comment. Replacement never resets an attempt count; billed USD is
carried forward as telemetry. No USD figure is a ceiling.

## 13. Bookkeeping and digest

PR bodies and completion reports hold implementation evidence. GitHub native
relationships hold structure. Generated board state and digest output hold
operational status. Do not copy these artifacts into chat or memory.

No packet manifest, evidence file, or hash comparison is required of any lane;
the report and the transcript are the evidence. A host continuation note is at
most 2,000 bytes and holds only: host identity, active lanes as
issue, lane, role, and start instant, pending host actions, open breakers, and
the next ready rank. Watchdog, PID, byte-count, and digest prose belongs in the
dispatch log and generated digest, never in the note.

## 14. Telemetry

Use `log-event.ps1`; never hand-author JSONL. Record exact model version,
routing row, placement, transcript, issue/PR/head, lane role, outcome, and
schema-specific identity. Event schemas and reducers in runtime are canonical.
`landed-integration-dispatch/v1`, `rebase-only-continuation/v1`,
`watchdog-dispatch-routing/v1`, and `watchdog-relaunch/v1` are closed lifecycle
variants produced only there;
duplicate landed-target and watchdog-observation identities are rejected.
LAUNCHED/WATCHDOG_RELAUNCH rows are appended only after an exact closed
dispatch-start acknowledgement; launch failure appends no success identity and
remains retryable without incrementing a relaunch count.
`log-event.ps1` refuses an ordinary exact-head review receipt unless its PR is
a positive supported whole number; controller-review schemas remain a distinct
strict variant.

Required event families are dispatch, review, verify, repair, enqueue,
landing, deploy verification, stall, breaker open/clear, replan, decision, rule
change, and escaped defect. The host writes only lifecycle event kinds;
`bookkeeping`, `note`, and `flow-snapshot` are not accepted. Terminal events
bind to the exact attempt and head. Unknown or incomplete authority is represented explicitly, never coerced
to success.

Every `breaker-clear` repeats its open row's `-Issue` and `-Pr` so the reducer
pairs them. Every `review-complete` and `verify-complete` row carries `-Classes`
for every matched defect class so second-bite counting remains complete.

Keep cost probes bounded. Advisory probe failure records null/degraded
telemetry and never blocks the cycle. Spend rolls up once per UTC day; no
per-cycle harvest reconciliation rows. The retrospective override-rate
vocabulary is retired with the decision machine (archive).

## 15. Learning

Run same-cycle retros for breaker clears, escaped defects, diagnosed stalls,
failed irreversible operations, and remedy recurrence.

- New pattern: add one ledger entry.
- Existing pattern: update it; do not duplicate it.
- Standing behavior change: update this skill or the authoritative runtime,
  bump the version, log `rule-change`, and pass independent review/install.
  A Todd-authored change takes one independent review and installs at once,
  with proof scoped to its change (§7); a controller-authored change takes
  the same one review and installs at once. A Todd ruling
  that changes runtime behavior is implemented within seven days; parking a
  ruling's implementation, or conditioning it on an
  empty product frontier, is prohibited.
- Recurrent pattern after remedy: mark the remedy ineffective and re-diagnose.
- Quality verdicts are retro input: recalibration reads `NOTE` counts by
  key, side, profile, and author model from the review receipts and tunes the
  profile weight table only when Todd asks for a recalibration; a pair side
  whose non-blocking findings recur after remedy gets a mechanical guard issue,
  not a longer review.

A terminal-park replan is accepted only when its body contains exactly one
ordered `changedSinceLastFailure` packet defined by
`contracts/planning-repair-v1.md`, its changed fact is material to the recorded
failure, and a `planning-repair/v1` completion receipt plus a fresh
independent semantic PASS bind the exact current body revision. Prose,
`changedSinceLastFailure=true`, a label, readiness-only evidence, a new model,
more effort, elapsed time, renewed willingness, or restated evidence alone never
reopens the item. An accepted replan proves only a material changed fact and a
bounded approach; it resets no attempt count, and billed USD is telemetry.

At a Todd-requested recalibration, merge same-parent ledger variants into
families and
archive structurally eliminated causes without deleting evidence. Keep the
normal dispatch surface bounded: query results, not ledger size, determine
context cost.
