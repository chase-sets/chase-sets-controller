---
name: milestone-orchestrator
description: "Product loop only (Chase Sets delivery from the product container): Run the chase-sets delivery loop — complete all committed, non-parked outcomes by routing work to dynamic Codex/Claude lanes, keeping the merge queue fed and deploys verified green, sending Todd only product priority or scope questions and packaged operator actions. Use when orchestrating milestone delivery, running the delivery loop or goal, managing lanes, landing PRs, or supervising the pipeline."
---

# Milestone Orchestrator (v2.117, 2026-10-18)

Read `orchestrator-shared` first (`~/.claude/skills/orchestrator-shared/SKILL.md`); its contract applies here and is not restated.

Version 2.116 makes this skill product-only (Todd, 2026-10-17/18). Controller
code and releases, the orchestration-platform migration, and routing,
velocity and capacity improvement belong to the separate controller thread in
`D:\Users\ToddS\Source\Repos\chase-sets-controller`. A controller release is
an annotated `controller-v*` tag on `chase-sets/chase-sets-controller`;
this skill only applies released tags (§2). Routing remains data-bound as in
v2.87; prior release notes are archived in
`references/rule-provenance-v2.24.md`.

Controller dispatch is data-bound rather than release-pinned: routing-policy
generation selects a row slot, model-registry current identities and admitted
account authority select the exact model, and a validated last-known-good copy
is visibly flagged when fresh authority is unavailable. Ownership, watchdog,
start-ack, and strict-review receipts retain policy generation, registry digest,
family, slot, and LKG provenance. Historical identities remain readable only;
fallback chooses the other policy family slot and never guesses a replacement.

Run the lifecycle in this file. Runtime scripts and contracts are authoritative
for their schemas and mutations; do not restate or bypass them.

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
Reviewed controller additions are in `references/controller-defect-classes.md`;
the ledger query includes them without replacing the machine-maintained pair.

## 1. Mission and authority

Terminal condition: every committed, non-parked milestone is closed and no
issue globally remains `status:needs-replan`. Candidate outcomes remain visible
future triage outside terminal completion. Parked means Todd deliberately
deferred the work, with a stated un-park condition (4388/6022146271). No
attempt count, dispatch count, reviewer-eligibility gap, or environment or
tooling failure parks work. Stopped implementation is active recovery work
labeled `status:needs-replan`, not parked.

Standing invariants:

- Keep the merge queue fed while runnable work exists.
- Verify the last real deploy green before enqueueing continues.
- Never let a worker self-certify.
- Send Todd only product priority or scope questions and packaged operator
  actions (§11), and never wait globally on either.
- Keep exactly one active orchestrator and one merge-queue writer.
- Optimize issue-to-deployed cycle time, not raw deploy count.
- Route, verify, land, and record. Never implement, debug, or repair product
  work in the host context; dispatch a bounded lane.

Scope boundary: this orchestrator builds the Chase Sets platform and nothing
else. It never supervises the orchestration platform loop. Controller work and
controller defects follow `orchestrator-shared` (Two loops, Defects). Record
each use of the `orchestrator-shared` Defects exception as `escaped-defect`.

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
The orchestrator and its lanes never run an unscoped recursive enumeration of `.orchestrator`, `logs` or `artifacts`; use exact paths or `rg --files -g <glob>`.

At session start and at step 1 of every cycle, run
`.orchestrator/check-controller-skill-freshness.ps1 -Json`. It reports the
installed release tag, the newest `controller-v*` tag on
`chase-sets/chase-sets-controller`, and whether the installed skill files
match the container checkout. When a newer tag exists, apply it before
dispatching with `.orchestrator/install-controller-skills.ps1 -ReleaseTag
<tag>` (it refuses while a heavy verifier owns the host; retry next cycle),
then re-read this skill and `orchestrator-shared`. A `stale` report with no newer tag is a controller defect: file
it and continue product work.

Publish no routine narration while the board and generated digest are healthy.
Post a status entry on #4388 only after a landing, a breaker change, or two
hours without one, at most 1,500 bytes. If a state surface is unavailable,
report that loss and fall back to terse check-ins until restored.

## 3. Cycle

On every wake:

1. Renew the host identity record and apply any newer controller release (§2).
2. Verify the newest actual deploy execution; update breakers.
3. Land only exact-head-authorized green PRs through `landing-preflight.ps1`.
4. Run `cleanup-orphan-worktree-dirs.ps1 -Remove -ReportPath
   .orchestrator/logs/worktree-reclamation-<yyyyMMddTHHmmssZ>.json` every cycle.
   Run `runtime-retention.ps1 -Apply`; it archives seven-day-old eligible output only when no verified manifest is newer than 24 hours.
5. Run the stall watchdog and inspect active-lane deltas.
6. Validate completed lanes and run independent review.
7. Backfill or scale from the live runnable frontier.
8. Sweep for decisions and operator actions; log each packaged Todd action
   change as `todd-action` (§11).
9. Record terminal events.
10. Run `board-reconcile.ps1 -Apply` once per cycle, at most hourly.
11. Publish `digest-publish.ps1` output; never hand-type the digest.
12. Run `waiting-on-todd.ps1` once, in the foreground. A refusal writes
    nothing; repair its named cause, never hand-edit the pinned issue.

No flow snapshot, replan reconciliation, or metrics check exists in the cycle.

### Orchestration platform

The orchestration platform loop and its migration belong to the controller
thread. This orchestrator does not observe, start, stop, upgrade or repair
platform supervisors or executors and never touches the platform checkout.
Once per cycle, before step 7, it applies `orchestrator-shared` Platform
handoff from `.orchestrator/platform-handoff.json` and complete issue reads:
it resumes unfinished take-backs, takes back held issues that meet a
take-back reason, files one controller defect for each return not
acknowledged within `releaseHours`, returns acknowledged issues to normal
delivery, then hands off new ones. When Chase Sets `main` or the actual deploy
is red, handle it as usual and leave platform-side causes to the controller
thread.

## 4. Work selection and ready gate

`orchestrator-shared` Platform handoff decides which issues the platform loop
holds; milestone membership never does. Selection already excludes issues
carrying `dispatch:platform` or `dispatch:platform-return` (`PLATFORM_HELD`).
On such an issue, its PR or its branch, the host never dispatches, reviews,
enqueues, rebases, closes, reclaims worktrees, runs its watchdog, or kills
processes, and a taken-back issue is runnable again only when that contract
returns it. All platform-repo issues belong to its self loop; the host never
dispatches lanes there. Unknown label state is not mutation authority; retry
the read while unrelated work continues.

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
Choose the next committed outcome within Todd's current product priority by
explicit Todd steering first, then native entry/exit gates and dependencies,
blocking criticality, evidenced value of finishing the whole admitted outcome
relative to remaining effort, continuity, and aging. These criteria never
select a new product priority. When the current steering's condition is met,
or the next product outcome would fall outside Todd's current priority, the
host files one short priority question under §11 and keeps delivering the
remaining committed work meanwhile.
Preserve the current TCGplayer-first steering until its recorded condition
is met or Todd supersedes it; do not encode its live issue numbers here. Existing approved priorities and `Dispatch rank` order ready issues inside
the selected outcome. Do not use the unvalidated impact-scoring pilot or invent
a replacement score.

Todd owns product prioritization (4388/5838628573). He decides which product
outcome or pilot is the current priority, and whether accepted product scope
is added or dropped. When evidence suggests such a change, the host files one
short priority question under §11 and keeps delivering on the current
priority meanwhile. Inside that priority, agents still create, split, place
and rank outcomes and issues. They also place all ops, test-infrastructure,
controller and platform work.

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

Product floor (4388/5838576100): while ready, runnable `kind:product` work
exists, at least two lanes serve it. Controller, platform, ops and
test-infrastructure work take only the remaining capacity. When fewer than two
product issues are ready, planning lanes that make product issues ready come
before new ops or test-infrastructure probes. Recovery planning for a
`status:needs-replan` issue in a committed product outcome is product-floor
work (4388/6022146271). Heavy-verifier slot order is
unchanged, and nothing preempts a live heavy owner.

Serial blocking backfills the floor (4388/5845981597). When Todd's current
priority outcome has fewer ready product issues than the floor, the remaining
product lanes take ready `kind:product` issues from the next committed
outcomes in marker order, regardless of track or the per-track pull window.
Backfill is not a priority change and files no §11 question. The current
priority keeps first claim on each lane that frees, and backfill never
preempts a running lane.

Ready means:

- The repo planning skill's issue-standard checklist passes. Body size is
  never a readiness gate; bound prompts at dispatch instead.
- The issue is executable, refined, and in a committed outcome selected by the
  shared dispatch window or admitted by the floor backfill above.
- Open GitHub blockers are absent. A probe, diagnostic or test-infrastructure
  issue never blocks a product issue unless the product change cannot be
  written without its output (4388/5845981597). The host removes such a link,
  records it on #4129, and the diagnostic runs in parallel.
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

Fresh implementation, planning, review and decision routing may consume a valid, active,
fresh capacity forecast under model-routing's "Capacity-balanced fresh
dispatch" rule (Todd 4388/6098327249): toward Claude every off-Claude row flips
to its own Claude slot and logs `override-Todd`; toward Codex the ordered
prefix still applies. Shadow computes only `capacityShadowFlip`; rejected input
preserves ordinary routing. Row 0, relaunches, integration dispatch/resume, and
a host-verified per-artifact Todd override are exempt before forecast read. The
host binds the Todd reference to branch, exact head and requested
row/harness/model/effort/placement in the closed `-ToddRouteOverride` JSON;
dispatch refuses incomplete or mismatched claims. Standing Todd placements are
not this exemption. Pass the positive `-Issue` on every planning, review and decision
dispatch and `-ReviewArtifact brief|code` on every product review; independence
means a fresh lane and session with no shared transcript or conversation state
with the author lane. Reviews and decision lanes use their row's policy slot
even when the same family authored or repaired the artifact. Authorship never
forces a third model. Astra and Fable are ordinary candidates wherever best
for the job; any off-slot lane records its reason in the dispatch row, the
same for every model. Read Fable's weekly window live from AgentPools
`/api/summary` `modelLimits`, scope `Fable`, window `limit:2`, and honor it like
any other quota window, not as a share rule. Respect quota windows and
`newLaneAllowance`. Dispatch v3 records all five capacity fields for every
role; calibration separates active flips.

A strict controller review is prepared, prelogged, then launched, in that
order: run `dispatch-lane.ps1 -PrepareRoute` with the full review request,
prelog the returned `strictPrelogV1` through `log-event.ps1` (map `reviewerModel`
to `-Model`, with `-Kind dispatch -LaneRole review`). Governing receipts remain
v1 until all terminal/install consumers support v2. Launch the same request.
A launch refusing `STRICT_PRELAUNCH_TUPLE_REQUIRED` voids never-launched prelogs
through the closed `controller-review-prelog-void/v1` row, naming each voided or
refused hash, with no launch output, snapshot, ownership record, v3 row or
process. A prelog void supplies no review authority. Re-prepare with a fresh
`-Label` and `-ReviewerAttempt`; the same seat is allowed. Other refusals and
preparation void nothing.

Every dispatch uses `.orchestrator/dispatch-lane.ps1`. Never author a one-off
launcher. Every implementation call supplies its exact `-Row` and `-Placement`;
the launcher persists both in the watchdog spec. Set `-LaneRole` to:

- `implementation`: product changes in the assigned worktree.
- `review`: no provider credentials; mutation is limited to the mechanical
  remedies and brief-body repairs that `contracts/review-v2.md` and §7 allow.
- `planning`: read-only repo plus bounded GitHub planning mutations.
- `decision`: read-only decision work with no planning-repair contract or GitHub write authority.

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
- The sole exception to ordinary clean, attached implementation admission is
  `-InterruptedIntegrationResumePath`, a closed
  `interrupted-canonical-integration/v1` binding. It permits only an
  implementation lane on row 7's current policy slot for its harness (the
  slot's current model and effort, with reserve placement as override-Todd) or
  on the retained astra/codex or fable/claude tuple at high, row 7,
  override-Todd; an attached v3 successor also needs exactly the tuple its
  bound prior launch recorded. Prior launch,
  start acknowledgement and request, canonical helper conflict, PR, original
  branch/head, onto, stopped HEAD/commit, native todo/done, complete index
  stages, and every changed byte must agree. Historical first stops require
  independent native replay in disposable scratch space; capture alone is
  not authority. Original branch and remote PR/head must still equal the
  original head. Prove prior roots and possible descendants dead and the full
  canonical worktree/ownership inventory vacant, then repeat these checks
  under the existing fleet admission before plan or owner publication.
  Refusal preserves the target bytes. Detached native rebase retains its
  original logical branch for competing claimants without claiming attachment.
  Only the admitted implementation child may resolve and call the canonical
  helper with `-ContinueInterruptedIntegration`; a fresh rebase, abort, reset,
  stash, skip or normalization is never part of admission. Later stops need
  the live bound child or fresh admission against its exact current checkpoint.
  Start/watchdog/release/retry preserve the versioned binding. Clean attached
  finish and original-head lease publication use the existing native completion
  checks; resume provides no review, provider, CI, enqueue or landing authority.
  The ordinary-author variant (#9334) is the same closed binding at
  `interrupted-canonical-integration/v2`: a schema-4 implementation author with
  no landed request, start acknowledgement or runtime prompt whose canonical
  helper stopped under the actual wrapper/relative-helper/logging/NoPush
  grammar, proven from its retained watchdog, routing row, prompt, transcript
  and the helper's own conflict capture when present. Its native plan is the
  sequencer's topo-order no-merges pick list, never raw reverse history. The
  same admitted actual owner finishes locally with `-NoPush`, commits
  repair/test changes as plain commits, and publishes exactly once through
  `-PublishInterruptedIntegration` under the immutable original-head lease;
  finished-unpublished has no completion, acknowledgement or acceptance, and a
  refused publication preserves bytes and history.
  Ordinary continuation requires NoPush before mutation. The host binds the
  exact FINAL-derived repair/test paths in the execution's authenticated prompt
  using `ordinary-integration-repair-authority/v1` in the owning evidence
  contract. Publication and completion check every repair commit, not just the
  net diff; pushed or bare-R finishes never complete. Landed defaults stay unchanged.
- Every launch injects the bounded retrieval contract after the heavy-gate
  preamble and before any harness, review or planning preamble; it bounds
  displayed output, never required evidence inspection or what a role may mutate.
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

The watchdog and termination rules below apply only to incumbent-owned lanes.
Platform liveness and stops follow section 3, never incumbent watchdog repair.

Arm native PowerShell 7 `lane-stall-watchdog-batch.ps1 -LanesPath <absolute-json-path>`
for every incumbent active batch. The UTF-8 input is a nonempty JSON array of
objects with `label`, `runtimeRoot` and canonical `transcriptPath` (the exact
`<runtimeRoot>/<label>.jsonl` from dispatch). Use native absolute paths, including
spaces and drive colons; only retained `/mnt/<drive>/...` paths are translated.
Optional `progressPath` names the known growing session-output file when the
canonical report is buffered. It supplements growth observation, never replaces
the canonical transcript passed to the reducer. Missing files/inputs fail closed.

Keep this finite command foreground-owned; when a Windows host starts it, use
a hidden window and retain/wait for its exact process rather than detaching a
daemon. Confirm its `STARTED` report and matching PID/start identity within
roughly 60–90 seconds. Retain the input hash, exact lanes/paths, source head and
entry/reducer hashes with that report. Defaults remain 120-second polling,
three unchanged polls and a 7200-second window. Growth resets the unchanged
count; a live-slow observation does not stop monitoring. `EXIT` repeats the
watcher/source identity: `ALL_TERMINAL` is graceful completion; `WINDOW_EXPIRED`
claims only expiry, not healthy lanes or absence of stalls. Re-arm after expiry
while work remains. `TRANSPORT_FAILURE` is nonzero and requires manual observation
until transport is restored; it is not a canonical lane-health state.
A `REDUCER_FAILURE` event is different: once a reducer has started for a lane,
its nonzero exit (even with valid JSON), missing/malformed/unsupported result,
or recovery-age refusal is contained to that lane under the closed codes
`REDUCER_EXIT`, `RESULT_INVALID` and `WATCHDOG_RELAUNCH_WINDOW_EXPIRED`,
carrying only the lane label and detection instant, never raw output. Sibling
lanes and later sweeps continue, the failed lane stays watched with its cadence
reset, and its unresolved flag clears only on a later valid,
non-`DUPLICATE_SKIPPED` reduction, never on transcript growth. `EXIT` keeps its
actual reason and reports `unresolvedReducerFailures`; a positive count is a
nonzero exit requiring host diagnosis of that lane, even at `WINDOW_EXPIRED` or
`MEMBERSHIP_CHANGED`, and is never `ALL_TERMINAL`, lane health, or terminal.

Re-arm with a complete fresh input snapshot when membership changes. Updating
the input file makes the old watcher exit `MEMBERSHIP_CHANGED` at its next poll
boundary, after any foreground observation finishes. Wait for that exact exit
before starting the new batch; never overlap watcher owners for the same lane.
A reducer
`RELAUNCHED` result follows its canonical replacement transcript and emits
`MEMBERSHIP_CHANGED`; re-arm to supply any replacement session progress path.
The retained `lane-stall-watchdog.sh` only reports `TRANSPORT_FAILURE` and exits
nonzero; it no longer attempts WSL interop or reports false stall/success.
Source tests are not coverage: after reviewed install, retain an installed-head-
bound live `STARTED`, native observations and graceful `EXIT` before claiming it.

Each cycle compare transcript growth, owner process, commits, PR state, and CI:

- Any delta is progress.
- One no-delta cycle: inspect bounded interim output.
- Two no-delta cycles: diagnose mechanically, terminate the exact owner, and
  re-dispatch or replan.

Long external work gets an expected completion time and bounded polling.
Transcripts are diagnostic evidence, never vacancy authority.

The reducer observes every dispatched role (implementation, planning, review, decision):
`LIVE_SLOW`, `TERMINAL_SUCCESS` and `OWNERSHIP_UNKNOWN` apply to all of them,
and `LAUNCH_PENDING`/`LAUNCH_FAILED` keep a lane watched. Recovery below is
implementation-only. A valid, stopped, proven-dead, non-successful planning,
review or decision lane returns `OBSERVATION_ONLY`: host diagnosis, not health, terminal or
vacancy authority, and never a relaunch, kill, or ledger effect.
A verified mechanical death is processed by `lane-stall-watchdog.ps1`, wired
from `lane-stall-watchdog-batch.ps1`, within five minutes of observation. Harness
death resumes the exact partial/worktree on the same configuration; quota or
session death is classified only from the native provider terminal envelope
and uses only the current routing row's closed qualified fallback table. The
installed runtime uses the current row policy fallback for quota and session
death; rows 9/11/12 remain closed for host diagnosis, while retained legacy
Astra/Fable sources move once to the current other-harness policy slot.
Policy reserve is logged as override-Todd. A
`watchdog-lane/v3` integration lane uses row 7's current policy-slot author;
historical Astra/Fable tuples remain observable through historical-read
validation. Author lanes and watchdog relaunches retain that uppercase spelling;
strict controller-review dispatch and receipt tuples instead use `override-todd`,
as required by the strict classifier (#8064). A
closed v2 specification carries that route directly. The bounded v1 adapter
accepts only one exact `watchdog-dispatch-routing/v1`, v2 or v3 canonical row matching the
same attempt/lane/transcript/configuration/worktree/branch/head; missing,
ambiguous, wrong-head, wrong-attempt, or wrong-configuration evidence is a
closed provenance refusal and never selects a row or fallback. A
supported configuration without one records `lane-blocked`/
`NO_QUALIFIED_FALLBACK` instead of inventing a move; policy fallbacks are
recomputed from the current routing generation, while historical sources stay
readable. The four own-slot Claude quota fallbacks in model-routing apply
whether or not the original author was flipped. `dispatch-lane`
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

Ordinary occupancy uses schema-v4 ownership; interrupted integration uses
schema-v5 with its closed binding. Both retain one `launchId`, bounded label, unique
runtime-root transcript, and exact launcher/child identity. Only exact owner
exit releases occupancy. Missing, malformed, truncated, aliased, or legacy-live
ownership is `unknown` and fail-closed for capacity. Before a reviewed ownership
schema cutover, require the candidate reducer to report
`legacyLiveOwners = 0`.

## 7. Review and replan

A lane must not launch model CLIs or subprocess reviewers itself. Required
independent review returns to the host as `PENDING_HOST_REVIEW` for canonical
attributed dispatch after full artifact history and row-slot admission checks;
bypass output is non-governing evidence, never review or admission authority.

Count every in-body brief repair in that model's artifact repair history. If no
admitted independent brief reviewer remains, never add a sweep or cleanse history.
For a nonterminal, outcome/decision/acceptance-preserving repair, the host may apply
FINAL `brief-sweep2-authority-decision-r1`'s standing proof route: bind the completed
repair, current body/dependencies and full findings in a causal exception record;
retain trusted readiness and ordinary admission; use a row-qualified author and a
fresh-session reviewer on the row's policy slot for one complete exact-head implementation
review that challenges the whole brief and all findings before ready/landing.
This is not a brief semantic PASS. Terminal re-entry, changed semantics,
missing authority or no eligible implementation reviewer remain outside this
route and return to independent decision. No attempt, blocking-round or landing
rule changes.

Reviewer exhaustion never parks or stalls an artifact (4388/6022146271). When
choosing a reviewer, the host dispatches the row's policy slot regardless of
which model authored or repaired the exact artifact. The reviewer is a fresh
lane and session with no shared transcript or conversation state with the
author lane, and the receipt discloses earlier participation in the lineage.
This is never self-review. No lane reviews its own output in the same session.

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
full battery as a precondition. For database-touching incumbent work, the
normal final-head hosted `DB Profile Tests` job is the DB proof
(4388/5838576100).
- While #8159 is open, no brief, decision or host prompt makes a full local
  `verify:test-db` a prerequisite for push, draft, ready or landing.
- A brief that already names one takes the hosted substitution with a PR-body
  disclosure, and no per-issue decision is needed.
- Hosted gates, timeouts, skips and reviews are unchanged, and local failures
  are not classified as environmental.
- Local-gate investigation stays in the #8159 lineage, and no new local-gate
  probe or diagnostic issue opens outside it. When that lineage yields no
  bounded repair, #8159 escalates through the recovery ladder below; it never
  parks automatically, and only Todd may defer it.

Hosted CI is the proof for every product attempt, not only DB
(4388/5845981597). The hosted jobs on the pushed head decide it, including E2E,
DB Profile, unit, static and build.
- Local E2E, local `verify:test-db` and other local full or harness runs are
  diagnostics only. No brief, decision or host prompt makes one a
  prerequisite for push, draft, ready or landing.
- A local-harness, environment or lock failure never parks, fails or
  classifies a candidate. The lane pushes its candidate to its draft PR and
  hosted CI judges it.

Planning, review and native row-13 documentation lanes inspect evidence and
run cheap focused checks only. They cannot reserve either heavy slot in any
mode. Heavy reproduction returns to the host for an attributed implementation
or verifier execution, supplying evidence rather than review authority. Exit
73 is non-execution, never PASS or a consumed attempt. A scoped refusal never
escalates to a full gate; preserve and disclose the defect. Non-doc controller
authors retain baseline-aware release proof under the separate controller slot.
Standalone host verification, including the fleet gate and host battery, requires
a healthy complete native census proving no containing launch; command shape,
prompt, lane name and inherited tokens are not caller authority.

A reviewed draft PR is always the
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

Recovery is judged, never counted to a stop (Todd, 4388/6022146271). After
every non-PASS (a blocking review or a red hosted verdict), the blocking receipt
or the host names one failure class, and the class sets the next step:

- Mechanical (stale pins or counts, type or lint errors, generated output,
  fixture counts): the reviewer or author repairs in place; it consumes no
  implementation attempt.
- Environment or tooling (harness, launcher, quota, sandbox, hosted-runner
  infrastructure): link the tooling owner as a native blocker; the artifact
  resumes when that blocker lands, with no attempt consumed.
- Implementation defect with a known remedy: resume the author with it.
- Brief defect (missing context, impossible or contradictory acceptance):
  `ISSUE`-level replan.
- Slice defect (wrong boundary, cannot be proven alone, or a cause shared with
  siblings): `SET`-level replan across the named siblings.
- Design defect (the approach does not work): `EPIC`-level replan or a bounded
  design spike.
- Product scope conflict: one §11 priority or scope question; unrelated work
  continues.
- External dependency (credentials, provider, counsel): `status:needs-operator`
  or a native blocker.

Escalate the level, not the count. The same root cause recurring at the same
level moves the next step up one level: implementation, `ISSUE`, `SET`,
`EPIC`, product scope. While blocking findings and red required jobs shrink
from one judged head to the next, keep repairing at the current level whatever
the attempt number; an oscillating or growing set escalates one level.

Implementation attempts are counted as telemetry and step-back triggers, never
as a stop. Review, repair, and planning rounds never count toward this
step-back trigger. An implementation attempt counts only when a pushed head
receives a hosted CI verdict or an exact-head review verdict
(4388/5845981597). Local-only failures, preparation stops, harness or
environment failures, lock refusals and a lane's own tooling defects do not
count; the lane repairs them within the same attempt. Existing counts are
recounted under this definition. That is a recount, not a reset: an attempt
that did receive a hosted or review verdict keeps counting. No further dispatch binds to it until that verdict is recorded.

At every fourth counted implementation attempt, the next dispatch for that
artifact is one independent step-back review (§11) over the whole lineage, its
siblings and its epic. Its verdict is final and is exactly one of `CONTINUE`
with a named remedy, `REPLAN` at a named level, `WAIT` on a named native
blocker, `PRODUCT_QUESTION` (§11), or `RECOMMEND_NOT_COMPLETING` (only Todd
closes the issue). The step-back review never parks and never asks Todd for
a ceiling. It complements the three-round repair rule; it never relaxes it.

Semantic implementation G1 identity and attempt counts persist across repair.
The lane name identifies the current author or reviewer execution; it is unique
while live through ownership-v4, not globally single-use across historical
receipts. Historical attempt fields remain readable audit evidence and are
never rewritten, but reuse on an unrelated issue/head cannot poison a current
controller candidate. Causal dispatch and terminal rows still bind one exact
lane/head tuple.

At 15 or more dispatches without any confirmed canonical landing, route one
independent step-back review under section 11, only at the pre-dispatch moment
for the open issue the host is about to route. Never sweep closed, tracking-only or non-candidate issues
or batch decisions at install. Before any further lane for that candidate, run
`scripts/query-ledgers.ps1 -DispatchIssue <issue> -DispatchCandidateState open -DispatchAuthority <authority>`.
Use the installed query with its canonical runtime root, not velocity's window
or a projection. Count each issue-bearing `kind=dispatch` row once, all roles,
all history; exclude issue-less aliases and other kinds. Any confirmed canonical
`landed` row (positive PR and exact head) suppresses the threshold forever.
UNKNOWN history/admission holds only this candidate for evidence reconciliation.
The host supplies `clear` only after checking existing terminal authority,
attempt admission and external gates; otherwise use `terminal-park`,
`attempt-ceiling`, `counsel`, `operator`, `todd` or `unknown`. These return no
threshold action. The fourth-attempt step-back review remains independent of
this count; this count grants no attempt, reset or dispatch authority.

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

Controller releases are not part of this loop. `orchestrator-shared`
Releases and Two loops state what this loop does with them.

Retired by v2.58 and archived in `references/rule-provenance-v2.24.md`: the
three-packet lifecycle, the #7495 bootstrap authority, the H1/H2/H3
legacy-to-strict bridge, the cutover recovery capability, and the
`AbortPreMutation` lifecycle. The provenance archive identifies that history
in the archive.

Any defect escaping a landed PR gets an `escaped-defect` event with a named
class. A second confirmed bite triggers a class sweep, structural guard with a
negative control, and a tracked guard issue.

## 8. Landing and deploy

An executing staging deploy does not replace the latest completed deploy
health; completed red remains unhealthy.

`merge-hold-state.ps1` is the sole producer of `merge-hold-state.json`
(`merge-hold-state/v1`). Initialize only after reconciling actual hold state,
using `-Action Initialize -ExpectedRevision 0 -Reconciled`; absence, prose,
an expired historical hold or `{}` is not initialization authority. Record an
authorized take only in its armed window, after every PASS product PR is
canonically enqueued: `-Action Take -ExpectedRevision <read-revision> -Armed
-ArmedWindowId <window> -HoldId <new-unique-id> -Issue <positive-issue>
-Scope queue|prs [-Prs <positive-PRs>] -ExpiresAt <UTC-within-two-hours>`.
Use `-Action Lift -ExpectedRevision <read-revision> -HoldId <exact-id>` for
the actual lift, and `-Action Disarm -ExpectedRevision <read-revision>
-ArmedWindowId <exact-window>` when disarming. Re-arm uses a new hold identity.
These serialized revision-equal updates retain take/expiry/release times;
expiry is inert observation, never an automatic lift. State records grant no
hold or landing authority. Unverified state remains UNKNOWN, never no-hold.

Enqueue, repair, and landed-integration actions below never touch an issue
carrying either platform handoff label (section 4), its PR or its branch,
including the direct-enqueue fallback. The landed-integration census records
such a target and never rebases it; the platform loop refreshes its own
branch. The complete census still observes those targets, but never
authorizes unrestricted auto-integration into a platform branch; do not
invoke a dispatch path that would mutate one.

`landing-preflight.ps1 -Action Apply` is the preferred enqueue path. It
must re-observe exact head, current review receipt, required checks, queue
eligibility, native dependencies, deploy health, and breakers immediately
before mutation. A PASS review with green required checks and no native
blocker is landing-authority-complete: the controller enqueues on its own
authority and no held landing order exists; Todd never enqueues on the
controller's behalf. A refusal of a
landing-authority-complete PR by any controller gate for a reason that is not
a product finding is a controller defect: enqueue the product PR directly once
with GitHub `enqueuePullRequest` (exact PR node ID, expected head OID,
`jump:false`) and append one `landing-stall` row containing the refusal reason
and actual enqueue result. An unknown mutation response is reconciled against
the queue before any retry; intent never becomes an enqueue fact. Manual
fallback on #4388 is used only when the direct mutation fails. File the gate
refusal as a controller defect (`orchestrator-shared` Defects). A non-authority-complete PR is never mutated,
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

These reclamation rules never remove a worktree, branch or process of an issue
carrying either platform handoff label (`platform-held-issue`), even after
idle, park, or merge, until `orchestrator-shared` Platform handoff returns the
issue.

After merge, remove the recognized incumbent PR's worktree and branch and
release its lane. Todd's 2026-10-04 directive also authorizes recognized-landed
worktrees: clean, unlocked, non-live, idle at least six hours, HEAD reachable
from base, with complete zero open head-PR and child-PR authority. Reclaim
recognized orphan branches only at their exact SHA; protect `main`, `archive/`
and `salvage/` on every branch-deletion route. Read each candidate's issue
labels and newest path-bound dispatch identity each run; unknown retains.
Remove nothing else without Todd's word: a dirty, unpushed, locked, or
unrecognized worktree is reported on #4388 with its path and head, not
reclaimed. Terminate only the exact lane owner and descendants, and release
heavy-verifier ownership only after the exact process tree exits. Keep salvage
and transcript storage outside skill discovery; stale `SKILL.md` copies and
ledger snapshots use archive names or extensions so search cannot mistake them
for live authority. `cleanup-orphan-worktree-dirs.ps1 -Remove` directly
revalidates identity, ownership, HEAD, branch tip, cleanliness and idle state
before each removal and atomically writes `worktree-reclamation-report/v4`;
no disposition packet or replacement ceremony exists.

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
- The provider has pacing headroom (#9316). Before adding lanes each cycle,
  run `capacity-pacing.ps1` once with the cycle's `-NowUtc` and add no fresh
  lane on a provider beyond its `newLaneAllowance`; respect live quota windows for every model. The lane budget (`laneBudget`) is the provider's paced
  lane count from each available account's headroom less the 0.10 reserve,
  its hours to reset and the provider's measured burn per lane-hour; the
  pace target (`targetUnitsPerHour`) and pace budget (`paceBudget`) come from
  a valid, fresh AgentPools pace on an in-force forecast. The pace target
  (`targetUnitsPerHour`) spends banked credits before they lapse; the pace
  budget (`paceBudget`) raises the headroom budget by at most two new lanes
  per run. A positive allowance with ready work is a reason to dispatch,
  not a ceiling to stay under. The new-lane allowance (`newLaneAllowance`)
  is that budget less the live
  census. Relaunches, resumes, review of in-flight work and landing are not
  counted against it. A zero allowance is a valid section 10 deferral reason,
  including in #9283's spend mode. `status: unknown` (an unreachable,
  malformed or stale status, or an unknown census) is zero allowance on every
  provider: pacing never authorizes dispatch on missing evidence. This
  reducer replaces the hand-read AgentPools dashboard routine of
  4388/6101785942, which is superseded.
  `paceBudget` is advisory unless reflected in `laneBudget`.

Backfill before adding lanes. Work-conservation beats soft harness
specialization.

## 11. Todd decisions and operator actions

Todd receives exactly two kinds of request (4388/5838600629 and 5838628573):

- **Product priority or scope question.** This covers which product outcome
  or pilot is the current priority, and adding, dropping or rescoping accepted
  product scope. Todd owns product prioritization.
- **Packaged operator action.** A step no lane can perform, for example:
  - an interactive or elevated action on the host;
  - an action that tool policy blocks for lanes;
  - credentials, accounts or payments only Todd holds;
  - contact with an external party such as counsel or a provider.

  Each request is one concrete runnable step, with its exact command or click
  path, and Todd can answer it without reading history. External approvals
  themselves, such as counsel sign-off, remain required and are never waived.

A decision is one comment on #4388 only when it is a product priority or scope
question for Todd. That comment states the question, the options, the
evidence, and the host's recommendation, and names the blocked issues. Todd
answers in the same thread; the host proceeds on the answer. There are no
tiers, modes, premise-freshness verdicts, or transition rules; the
two-tier/five-mode machine is retired (archive). The host keeps delivering on
the current priority while a question is open. Process decisions never become
#4388 questions for Todd; they follow the host and decision-lane routes below.

Every other decision stays with agents:

- **The host decides** same-attempt, in-scope repairs itself and logs
  `decision-resolved` with its reasoning. These include stale pins or counts,
  fixture collisions, sink or path mistakes, host prompt defects, continuation
  authority, and agent-owned placement.
- **An independent decision lane decides** a change to accepted acceptance
  criteria within the current product scope, a step-back review verdict (§7), a
  proof-route substitution, a bounded capture allowance, a staging data
  repair, or a cross-lineage choice. Its verdict is final, and the host
  proceeds on it.
- A decision lane never returns a Todd ruling for a process question. If it
  believes Todd must decide something that is not a product priority or scope
  change, the host resolves the question with a second independent lane.
- File genuine product, domain, legal, provider-contract, UX, data, and
  architecture Decisions immediately with options, evidence, recommendation,
  owner, and blocked issues. Each goes to a decision lane when it is inside
  accepted product scope. It goes to Todd only as a priority or scope question
  or a packaged operator action.
- Continue unrelated work. Never infer Todd's answer to a question he owns.

Do not file recurring cap-only, final-review, or park-or-continue Decisions
after v2.45 cutover. A PASS review is authority to push, publish, mark ready,
and enqueue; funding a bounded review, repair, verification, or re-review
never needs a Decision; and no authorization Decision is filed for work already
inside a ruled scope.

The section 7 threshold uses one independent decision lane, never a filed
Decision issue or a Todd question. Pending and final are once-only steady states:
never launch a second threshold decision. The host consumes the query's action:
`CLAIM_DECISION` records `CLAIMED` through `log-event.ps1 -DispatchDecision <json>`
before the sole canonical launch. Use `-Log dispatch -Kind decision-filed -Issue <issue>`;
this reuses lifecycle kinds, not Decision-issue filing authority. CLAIMED and
ACKNOWLEDGED still appear in decision-heavy telemetry and the pending digest.
The closed payload is `{schemaVersion:"dispatch-count-decision/v1",
id:"dispatch-count-<issue>-v1",phase:"CLAIMED",count:<query.dispatchCount>,
lane:<unique decision lane>,transcript:<exact canonical transcript>}`.
The logger validates and serializes each transition against complete history.
Ledger line order, not `ts`, is authoritative for the reducer.
Only the uninterrupted successful claim caller may launch `dispatch-lane.ps1`
with that lane/transcript. On claim/launch/ack interruption, `RECONCILE_DECISION`
recovers that same identity from canonical ownership/start acknowledgement and
the exact issue-bearing dispatch row, or reports bounded uncertainty; it never
blindly relaunches. Persist `ACKNOWLEDGED` with the same payload plus
`dispatchReceiptIdentity` (the canonical dispatch row's raw SHA256). A pending
container, lane-complete prose or launch intent is not a FINAL verdict.
The claim caller launches the decision lane once through
`dispatch-lane.ps1 -Issue <issue> -LaneRole decision`.
The worktree leaf must equal the claimed `lane`, and the label must make the
transcript equal the claimed `transcript`. That launcher's
`watchdog-dispatch-routing/v2` row is the single issue-bearing dispatch row,
and `ACKNOWLEDGED.dispatchReceiptIdentity` is its raw SHA256.
The host appends no other issue-bearing `kind=dispatch` row for that
lane/transcript: no VERIFIED, attribution or backfill `-Issue` row.
Multiple matching launches remain UNKNOWN rather than acknowledgement authority.
After validating that independent lane's final report, record `FINAL` using
`-Kind decision-resolved`, the same identity/count/dispatch binding and
the step-back verdict as `disposition`: `CONTINUE`, `REPLAN`, `WAIT`,
`PRODUCT_QUESTION` or `RECOMMEND_NOT_COMPLETING`; `PARK` is refused.
`CLAIM_APPLICATION` records `APPLYING`
before the effect, additionally binding `finalReceiptIdentity` from the query.
Use the query's stable `applicationId` as the replan lane label/transcript stem
or the verdict-comment marker, so restart reconciliation addresses the
same effect rather than constructing a new one.
Apply the final disposition once: Replan is planning work, not another decision lane;
every other verdict is one issue comment naming the verdict and its next step,
plus the native blocker for `WAIT` or the one #4388 question for
`PRODUCT_QUESTION`. Record `APPLIED`
only after the exact planning dispatch or verdict comment is confirmed, retaining
all bindings. `RECONCILE_APPLICATION` checks that same effect after interruption;
uncertain response means bounded uncertainty, never a second dispatch/comment.
`NONE` requests no threshold action; APPLIED remains steady across restarts.
Replan preserves consumed attempts and ordinary admission; counsel/operator
gates and Todd-only authority remain binding.
A terminal park or attempt-ceiling decision recorded before v2.103 is
re-triaged under §7 by one step-back review at its next dispatch moment; it is
not reopened through this threshold and needs no material changed fact.

Do not send routine milestone creation, splitting, rescoping, placement,
ordering, issue ranking, or scope tradeoffs within an accepted outcome to Todd.
Agents own those choices under §4. Escalate to Todd only when a tradeoff would
change product priority or accepted product scope. Other legal and external
authority reaches Todd only as a packaged operator action.

The existing Todd-reserved rules are unchanged: host rotation (§2) and
reclaiming unrecognized worktrees (§9). A platform handoff or take-back is a
host decision under `orchestrator-shared` Platform handoff, never a Todd
question. Status posts list only open priority or scope questions and link the
pinned Waiting-on-Todd issue for packaged operator actions; they never repeat
its list inline. They never list process decisions as waiting on Todd.

Packaged operator actions live on the pinned Waiting-on-Todd issue named in
`.orchestrator/waiting-on-todd.psd1` (#9229), not in #4388 comments. When the
host packages, updates or resolves one, it logs `log-event.ps1 -Log dispatch
-Kind todd-action -ActionId <id> -Issue <issue> -ActionState now|later|done
-Action <step> -ActionTime <estimate> -Unblocks <issues>`. The actionId is
stable and unique per action; one issue may carry several. Now is ready for
Todd, Later waits on gates that must pass first, and done resolves it. The
ledger is the only membership source: comments, labels and prose carry no
authority, because the host posts as Todd's account. Ambiguous ownership goes
to host triage, never to Todd. `waiting-on-todd.ps1` renders the pinned body
from the latest row per actionId (Now, Later, and Done for seven days),
assigns Todd to each issue with a Now action, and removes only assignments it
made. It journals each GitHub write before making it and confirms it by
readback, writes the body only while it is unchanged since the cycle read, and
writes nothing after a failed read. It also writes nothing while the pinned body
is still hand-written and no `todd-action` row exists, so install seeds the
current items first.

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
discharge through the §7 recovery ladder.

No artifact parks on attempts (§7; 4388/6022146271). There is no standing-cap
continuation row and no ceiling authority ceremony; the fourth-attempt
step-back review chooses the next step.
Replacement never resets an attempt count, and counts follow
the §7 attempt definition; billed USD is carried forward as telemetry. No USD figure is a ceiling.

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

Velocity alarms (#8207; 4388/5845981597). Every cycle the host runs
`.orchestrator/velocity-metrics.ps1 -Summary`, which records one observation
and reports `velocity-report/v1`. Run one Summary per cycle, foreground,
without per-PR Reports for velocity. DROUGHT is the only alarm; every
`metrics.floorState` UNMET requires the same-cycle response below, independent
of `status`, `alarms` and observation history. Other diagnostics do not trigger
work except the existing duty to repair named gaps.
For these metrics, `committed-product-milestone/v1` counts every issue kind in
an open committed commerce/mobile outcome, excluding issues carrying either
platform handoff label, the policy's named CI/controller-evidence milestones
and parked issues. A
`[controller]` title or canonical dispatch/review controller evidence at any
age excludes controller-owned issues. Ownership does not expire with the
observation window. Kind changes never produce
`lateProductRelabels`; that compatibility field remains empty (Todd, 2026-10-04
12:20Z). Flowing and ready use open issues; merge and lane-hour accounting use
the same milestone/ownership definition, including closed referenced issues.
Actionable ready-idle means current trusted `issue-readiness/v1` accepted by
main's `consumeIssueReadinessReceipt`, independent current-brief semantic PASS,
resolved prerequisites and section 4 window/backfill admission. The host passes
its already-verified considered-candidate evidence with `-DispatchQualificationPath`;
this transient input is not a readiness ledger. Bind repository, issue, node,
revision, body SHA256, all five milestone fields, trusted checker, workflow run,
semantic report and admission evidence. The host verifies the workflow artifact
and complete independent author/repair history before projecting them; comments,
prospective results and artifact presence alone confer no authority.
`Get-VelocityFacts` retains that source and current native inputs; facts replay
reconsumes main's `isRunnableRefined`, `readOutcomePolicy` and `derivePullWindow`.
Backfill consumes the host's section 4 priority assessment and marker-order
evidence, including current-priority first claim and non-preemption, never an
idle-derived permission. No new admission checker or action runner exists.
Missing, malformed, stale, failed or not-evaluated qualification is reason-coded
UNKNOWN/not-evaluated. `unblockedCommittedBacklog` and `backlogQualification`
remain diagnostic, with no per-backlog action duty. Summary only consumes
qualification; it never starts workflows or a corpus sweep. Unknown never proves
ready or readiness completeness. With no actionable or held witness below the
floor, unevaluated backlog leaves FLOOR UNKNOWN, not a no-ready-work proof.
Idle fields in JSON, Summary and observations are actionable-only; observations
mark `readyIdleDefinition=dispatch-qualified/v1`. Historical diagnostic rows do
not retroactively gain this meaning. Qualification never erases flow or holds.
- FLOOR: fewer than two product issues have an agent-owned next step (a live
  lane, running hosted CI, or the unblocked merge queue) while a ready product
  issue is idle or an exact-head PASS product PR is held.
  Held means ready, exact-head authorized and covered by a validated
  active merge hold; count each PR once with its hold identities, never as
  ready idle or queue-only flow. Independent live-lane, CI or unblocked-PR
  progress may still flow. Name both idle and held causes and the host action.
  For every UNMET cycle, dispatch each ready idle issue, or run its PR's next
  permissible step; `NO_REVIEW_HISTORY` means a first review. Otherwise record
  the concrete reason. A capacity/ordering deferral creates no marker and is
  reconsidered next cycle. Only a cause section 7's failure-class list already
  routes to a native blocker or `status:needs-operator` gets that marker,
  applied there; a product question goes to section 11. This response never
  creates a terminal park, `status:needs-replan` or an attempt change.
  A blocker stops blocking when it closes; remove `status:needs-operator` only
  after verifying the operator action completed. Lift or confirm each listed
  hold under section 8's authority; a held PR stays listed while held.
  Log one `decision-resolved` row with `velocity:FLOOR` in the note carrying
  the observation's exact `ts` and every `readyIdleIssues`/`heldPrs` identity
  with its action, concrete reason or marker. Identical consecutive cycles
  bind separately by `ts`. It needs no retro. A terminal park velocity misses
  is a facts defect: file it, never re-triage.
- With incomplete facts, FLOOR is MET only when every gap is additive-only or
  proven issue-local and at least `FloorLanes` flowing issues remain after
  removing the named issues. The case-sensitive additive-only allowlist is
  `review-reduction-unknown:<pr>`,
  `launch-issue-unresolved:<lane>`, `launch-issue-resolution-pending:<lane>`
  and `merge-hold-state-unverified`, with no hold exception. A valid reduction
  makes held decidable; an invalid one never adds queue or green-wait flow.
  Only `merged-issue-labels-incomplete:<n>`
  and `issue-details-labels-incomplete:<n>` are proven issue-local. Open-issue
  connection gaps can affect PR-wide hold state and are not issue-local.
  Every other gap, including malformed dispatch rows, whole-source failures
  and unknown/future kinds, makes FLOOR UNKNOWN; there is no blanket landing
  subtraction. Below the floor, incomplete facts remain UNKNOWN. Complete-facts
  behavior, `status`, `factsComplete` and `gaps` are unchanged. `floorProofIssues`
  exposes the remaining witnesses, or an empty set when gap scope is unknown;
  `flowingProductIssues` remains diagnostic flow, not the incomplete-facts proof.
- Live lanes join their canonical routing Issue, attempt, label and worktree,
  retaining live origins beyond seven days and exact relaunch labels. Supply
  positive `-Issue` on every dispatch role. Explicit Issue wins; only absent
  Issue permits a leading positive issue prefix matching this census, and
  `-cN` inherits only one unambiguous prior-seat issue. Unresolved owned lanes
  older than ten minutes are named gaps, never an idle FLOOR cause. The
  eight-hour staleness flag remains diagnostic only. Green open PRs with an
  exact-head live review/repair lane or bound enqueue/landing row flow once;
  without one they are actionable ready idle only with the qualification above,
  regardless of native review status; otherwise they remain backlog diagnostics.
  A same-PR, same-repository dequeue at or after a binding row unbinds it;
  a later re-enqueue rebinds. Future rows confer no binding or unbinding.
  A merged product PR flows as landing only with a landed row and no
  deploy-verified row between merge and now, regardless of landed-row write
  order, for less than 24 hours after merge. Terminal
  parks without admitted live re-entry stay in a separate diagnostic bucket;
  uncertain terminal evidence never becomes ready idle.
- DROUGHT: no product-milestone merge for 48 hours, re-armed every further 48
  hours. The host dispatches one independent diagnosis decision lane with the
  report, bounded to 60 minutes, and logs `velocity:DROUGHT`. Its verdict is
  final and is exactly one of: a repair of the named blocker; a rule change
  that removes at least as many skill lines as it adds; or, only when Todd's
  current priority is blocked by something external, one priority question
  under §11.
- UNKNOWN facts raise no alarm and never read as OK; the host repairs the
  named gap.
- A velocity rule change states the mechanism it should change and is checked
  48 hours after install. A miss re-diagnoses; it never auto-reverts and never
  adds a rule by itself.
  For #9123, retain installed head and the first non-UNKNOWN complete row,
  the no-per-PR-Report transcript, and every UNMET observation joined by exact
  `ts` and each listed identity to its same-cycle action row through install+48h.
  Require zero unmatched identities, distinguish repeated cycles, retain a
  queued product PR row if any, and prove deleting one action fails the join.
  No observed UNMET cycle is "not exercised"; zero UNMET cycles is unexercised,
  never invented coverage. The mechanism is same-cycle response and one-time
  native triage instead of the timed alarm and per-PR collection.
- Until the heartbeat ships in #8222, the host checks `unacted` in each cycle's
  summary (DROUGHT 4 hours only).
- Once a week the host posts one outcome summary on #4129: product merges,
  hours since the last product merge, flowing product issues, and what
  changed. It asks Todd nothing.

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
strict variant. `todd-action/v1` is closed: actionId, issue, state (`now`,
`later` or `done`), action, time and unblocks are all required, no other field
is accepted, and an actionId never moves to another issue.

Every brief intake, publication, edit and repair, including reviewer in-body
repairs and host CAS transport, must call the existing producer after exact
readback, not a generic model-bearing lifecycle note:

```powershell
& "$O/log-event.ps1" -Log dispatch -Kind decision-resolved -Issue $issue `
  -BriefRevision ($target | ConvertTo-Json -Depth 20 -Compress) `
  -BriefAttribution ($attribution | ConvertTo-Json -Depth 20 -Compress) -NoBoard
```

This emits the closed `brief-attribution/v1` variant: `ts`, `kind`, `issue`,
`briefSchema`, `briefRevision`, `briefAttribution`. `briefRevision` is the
independent eligibility marker/target, with `issue` (positive integer),
`artifact` (body or the exact Packet identity), `revision` (immutable published
revision), `bodySha256` (exact UTF-8 bytes) and `observedAt` (zoned instant).
`briefAttribution` always contains `operation`, `originalRowSha256`, `authors`,
`host`, `consumed`, `byteProof`, including explicit nulls/empty arrays. Each
revision declares its complete consumed ancestry, not a delta; it cannot
invent an omitted legacy edge. Selection uses the latest ledger-bound
revision, without GitHub reads. Missing, malformed, partial or stale eligible
facts are unknown, never empty ancestry. Pre-v1 projection stays unchanged.
An unmarked publication bypassing this caller remains an explicit legacy
residual, not repaired history or permission to bypass it.

An author is `{issue,attemptId,dispatchRawSha256,evidenceRawSha256,model,effort}`.
Bind exact original dispatch and author/repair evidence; retain the evidence's
observed effort or null, never fill missing effort from a different row. Raw
row hashes use UTF-8 excluding the line terminator. `host` is
`{model,effort,writing}`. `consumed` entries are
`{issue,artifact,revision,bodySha256,attributionRawSha256}`, pointing only to
earlier validated declarations. Shared links are not ancestry. Original code
roles and same-model/different-effort participation never get rewritten.

Before transporting lane-authored bytes, the author or host records an
`attestation` with the command above plus `-BriefEvidencePath <author-report>`:
one bound author, null host/original, empty consumed, and
`byteProof:{reportSha256,bodySha256,attestorDispatchRawSha256}`. Inspect the
author's own report/transcript and its attestation of the
prepublication bytes, retaining its exact hash, attempt and model. The
producer verifies that report's bytes and binding. A hash computed only from
the host's publication file is not an attestation. Publish only those bytes,
then record `publication`, its bound author, `host.writing:false`, and
`byteProof:{attestationRawSha256}`. For a host-written intake/edit with no
bound byte match, use `publication`, empty authors, `host.writing:true`, null
byteProof. Nonwriting without a matching attestation, changed bytes, or a
writer claim naming another author refuses `BRIEF_ATTRIBUTION_WRITER_CONFLICT`.

Truthful retrospective source attribution uses `retrospective`, the immutable
original row hash, exact original author/repair tuples, and the host-attested
artifact/revision link. It is stamped now, never backdated or synthesized as
a historical dispatch/completion. A nonwriting lifecycle decision uses
`participation`, its original row hash, empty authors/consumed and null
byteProof; it is not a publication exemption. Preserve every actual edit and
uncorrected historical conflict. Do not retrospectively attribute live history
without inspecting its original evidence. The producer validates the complete
history under the existing append lock; omission refuses
`BRIEF_ATTRIBUTION_REQUIRED`, other malformed/causal/conflicting/stale bindings
refuse `BRIEF_ATTRIBUTION_INVALID`. The reader retains
`REVIEWER_HISTORY_UNKNOWN`; no dispatch or strict-review schema is widened.

Required event families are dispatch, review, verify, repair, enqueue,
landing, deploy verification, stall, breaker open/clear, replan, decision, rule
change, escaped defect, and Todd action. The host writes only lifecycle event kinds;
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
- When automation replaces a host duty, remove the redundant routine in the
  same reviewed adoption change after its replacement coverage is exercised.
  Keep manual fallback for unavailable, stale or incomplete evidence, not as
  a parallel routine. Use existing issue/PR and execution evidence to check
  whether the action, wait or failure disappeared; add no report, approval
  stage or delivery gate.
- Standing behavior change to this skill or any controller runtime, or a Todd
  ruling that changes runtime behavior: `orchestrator-shared` Repository
  routing.
- Recurrent pattern after remedy: mark the remedy ineffective and re-diagnose.
- Quality verdicts are retro input: recalibration reads `NOTE` counts by
  key, side, profile, and author model from the review receipts and tunes the
  profile weight table only when Todd asks for a recalibration; a pair side
  whose non-blocking findings recur after remedy gets a mechanical guard issue,
  not a longer review.

Re-entry after a stopped attempt follows `contracts/planning-repair-v1.md`: its
ordered `recoveryHypothesis` packet names what the work does differently from
every prior hypothesis, and a `planning-repair/v1` completion receipt plus a
fresh independent semantic PASS bind the exact current body revision. A new
model, more effort, elapsed time, renewed willingness, or restated evidence
alone is not a new hypothesis; a repeated hypothesis escalates the recovery
level (§7) instead. Acceptance resets no attempt count and needs no ceiling
authority; billed USD is telemetry.

At a Todd-requested recalibration, merge same-parent ledger variants into
families and
archive structurally eliminated causes without deleting evidence. Keep the
normal dispatch surface bounded: query results, not ledger size, determine
context cost.
