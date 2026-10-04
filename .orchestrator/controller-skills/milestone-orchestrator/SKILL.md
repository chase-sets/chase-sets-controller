---
name: milestone-orchestrator
description: Run the chase-sets delivery loop — complete all committed, non-parked outcomes by routing work to dynamic Codex/Claude lanes, keeping the merge queue fed and deploys verified green, sending Todd only product priority or scope questions and packaged operator actions. Use when orchestrating milestone delivery, running the delivery loop or goal, managing lanes, landing PRs, or supervising the pipeline.
---

# Milestone Orchestrator (v2.97, 2026-10-04)

Version 2.97 observes held PASS PRs as a FLOOR cause, captures queued non-hold
landing evidence, and preserves live launch issue attribution (#8526). It projects
implementation/review board ownership on events and runs
the capped reconciliation backstop at most hourly (#8478). Native role/routing
heavy-slot eligibility, role-specific verification prompts and trusted CI-prior
battery reuse (#8528) remain unchanged, as do model-routing v4.20,
host-attributed review handoffs, the nonterminal exhausted-brief-reviewer proof
route and strict review-history reduction. Repair battery logs bind the admitted
baseline receipt.
Routing remains data-bound as in v2.87; prior release notes are archived in
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
future triage outside terminal completion. Parked means deliberately deferred
with a stated un-park condition. Stopped implementation is active recovery
work labeled `status:needs-replan`, not parked.

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
6. Validate completed lanes and run independent review; supervise both platform
   loops as below before step 7.
7. Backfill or scale from the live runnable frontier.
8. Sweep for decisions and operator actions.
9. Record terminal events.
10. Run `board-reconcile.ps1 -Apply` once per cycle, at most hourly.
11. Publish `digest-publish.ps1` output; never hand-type the digest.

No flow snapshot, replan reconciliation, or metrics check exists in the cycle.

### Platform supervision

Read the complete canonical `.orchestrator/platform-handoff.md` at the container
root for the ownership register, route table, executor policy, rollback, exit
criteria, and current handoff log. It is the readable contract of
[Todd's #4388 ruling](https://github.com/chase-sets/chase-sets/issues/4388#issuecomment-5664326394)
and platform #368. Apply the partition in section 4 to the entire cycle, not
only backfill. Continue incumbent-owned product delivery in parallel.

Each wake before step 7, observe both loops. Once ISS-136 is installed and
exercised on a real run, use its status command instead of routine log-tail
and process reconstruction. Do not repeat those manual reads for a current,
complete native observation. Before adoption, or when native evidence is
unavailable, stale or incomplete, observe both supervisor logs read-only with
`wsl -d Ubuntu -- tail -n 3 /root/orchestration-m1/supervisor.log` and the same
command for `/root/orchestration-m2/supervisor.log`. Check the exact
`supervise.mjs` process identity read-only: PID, parent/process group, start
instant, and command/config against the run's start record. A historical log
line or matching PID alone is not liveness. Unresolved evidence stays unknown;
unrelated incumbent work continues. ISS-138 alert silence is not health
evidence and does not replace current-state or pre-mutation checks.
Record a stop's route as one line on
`todd-skelton/orchestration-platform#367` while ISS-110 is open, then #368;
routine observation adds no status beyond the existing #4388 cadence.

Preserve the handoff route table without expanding its permissions:

| Observation | Route |
| --- | --- |
| Idle, empty runnable set, no admitted work blocked | Verify milestone completion and the actual deploy under section 8; seek Todd's #4388 ownership change and register edit before incumbent adoption, and propose the next small platform milestone. Idle never transfers ownership. |
| `status:needs-operator` work | Todd; no host action on the work. |
| Work-caused park (attempt ceiling, review fail) | The loop parks and continues; host files the planning repair, but no incumbent implementation while platform-owned. Unpark returns work to the loop. |
| Host/executor stop, including an unclassified stop or dead supervisor | Learning note on the platform tracking issue plus a `ready` ISS in the platform repo; the self loop fixes it. Resume only through the canonical path below. |
| Chase Sets `main` or actual deploy red | Incumbent handles only its own scope: breaker and one bounded author lane, plus a platform tracking note. A second recurrence becomes an ISS. |
| Failed hosted platform PR check | Native repair (ISS-124/ISS-141), never host rerun, close/reopen, or repair; PR #8005 belongs exclusively to that native path. |
| Issue routed to Claude by model-routing | Trigger for ISS-109; until it lands, keep such issues out of platform milestones. |
| M1 exits idle while ISS-110 is open | Expected when no ready issue exists in the earliest open registered milestone: the self adapter has no `targetMilestone`. Another ready ISS there may run while ISS-110 is open. Restart only when appropriate runnable work exists, including after ISS-110 closes; never repeatedly restart an expected idle run, edit the selector, or rehome ISS-136/137/138 to force selection. |

Never hand-edit the platform checkout or `/root/orchestration-m1/repo` executor;
platform defects stay with the self loop. Start or resume only from Windows via
the platform checkout's `scripts/executor/start-loop.ps1 <config>`, recording
config path, run name, executor SHA, and supervisor PID. Honor any active setup
owner until it reports that identity and releases responsibility; historical
setup completion is not a continuing setup hold. The shared executor moves to
`origin/main` only with no live M2 supervisor until ISS-137 pause exists; then
use its native pause contract. The self loop's between-cycle upgrade remains
ISS-133. This is not permission to stop M2 to upgrade it.

ISS-111 exit requires all of: ISS-110 closed on its own single-invocation,
end-to-end milestone terms (milestone 158 with restarts does not count);
ISS-136/137/138 landed AND used on a real run; one full milestone delivered
with zero incumbent touches, measured as manual host interventions per
delivered issue on #367/#368; and the rollback runbook landed AND exercised
once. Only a later qualifying controller release may retire sections 3-10 for
routine delivery, retaining section 11 and operator actions. The separate
Chase Sets docs PR owns `docs/runbooks/platform-loop-rollback.md`; writing or
reviewing it authorizes no rollback, platform process kill, or ownership change.
Rollback requires Todd's authorization and the runbook, not ordinary reclamation.

## 4. Work selection and ready gate

The native ownership register in the canonical handoff controls selection:
the incumbent's protected set must equal its platform-owned milestone rows.
Todd's current ruling protects milestones 155 and 158 exactly; do not freeze
that pilot list in dispatch policy. Future ownership changes require BOTH a
Todd comment on #4388 and the register edit, never inferred idle or completion.
All other Chase Sets scope remains incumbent-owned. All platform-repo issues
belong to its self loop; the host never dispatches lanes there. Platform
`targetMilestone` enforces the other side of the partition (ISS-135).
On platform-owned work the incumbent never dispatches, enqueues, rebases,
closes, reclaims worktrees, runs its watchdog, or kills platform processes.
Unknown ownership is not incumbent mutation authority; resolve the register
and ruling while unrelated incumbent work continues.

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
before new ops or test-infrastructure probes. Heavy-verifier slot order is
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
- The sole exception to ordinary clean, attached implementation admission is
  `-InterruptedIntegrationResumePath`, a closed
  `interrupted-canonical-integration/v1` binding. It permits only
  codex/gpt-6-astra/high, implementation, row 7, override-Todd. Prior launch,
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

The reducer observes every dispatched role (implementation, planning, review):
`LIVE_SLOW`, `TERMINAL_SUCCESS` and `OWNERSHIP_UNKNOWN` apply to all of them,
and `LAUNCH_PENDING`/`LAUNCH_FAILED` keep a lane watched. Recovery below is
implementation-only. A valid, stopped, proven-dead, non-successful planning or
review lane returns `OBSERVATION_ONLY`: host diagnosis, not health, terminal or
vacancy authority, and never a relaunch, kill, or ledger effect.
A verified mechanical death is processed by `lane-stall-watchdog.ps1`, wired
from `lane-stall-watchdog-batch.ps1`, within five minutes of observation. Harness
death resumes the exact partial/worktree on the same configuration; quota or
session death is classified only from the native provider terminal envelope
and uses only the current routing row's closed qualified fallback table. Under
Todd's vendor fallback ruling (4388/5743533387) that table sends a
quota-blocked or refused `gpt-6-astra` author to `claude-fable-5-1` and a
quota-blocked or refused `gpt-6.1-sol` author to `claude-opus-5-5`, each at the
same effort and placed `override-Todd` on any row, except that a
`watchdog-lane/v3` integration lane, whose author set stays closed to
codex/`gpt-6-astra`/high/row 7/`override-Todd` pending a separate ruling,
records `lane-blocked`/`NO_QUALIFIED_FALLBACK` instead of falling to
Fable 5.1. Author lanes and watchdog relaunches retain that uppercase spelling;
strict controller-review dispatch and receipt tuples instead use `override-todd`,
as required by the strict classifier (#8064). A
closed v2 specification carries that route directly. The bounded v1 adapter
accepts only one exact `watchdog-dispatch-routing/v1` canonical row matching the
same attempt/lane/transcript/configuration/worktree/branch/head; missing,
ambiguous, wrong-head, wrong-attempt, or wrong-configuration evidence is a
closed provenance refusal and never selects a row or fallback. A
supported configuration without one records `lane-blocked`/
`NO_QUALIFIED_FALLBACK` instead of inventing a move; the ruled Astra-to-Fable
5.1 and Sol 6.1-to-Opus 5.5 moves are closed table entries, never an inference from
capacity, and the relaunched Fable 5.1 row-7 author resumes an interrupted
integration through the same closed binding as the Astra author. `dispatch-lane`
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
attributed dispatch after full artifact author/repair-history eligibility checks;
bypass output is non-governing evidence, never review or admission authority.

Count every in-body brief repair in that model's artifact repair history. If no
admitted independent brief reviewer remains, never add a sweep or cleanse history.
For a nonterminal, outcome/decision/acceptance-preserving repair, the host may apply
FINAL `brief-sweep2-authority-decision-r1`'s standing proof route: bind the completed
repair, current body/dependencies and full findings in a causal exception record;
retain trusted readiness and ordinary admission; use a row-qualified author and a
fresh code-history-independent reviewer for one complete exact-head implementation
review that challenges the whole brief and all findings before ready/landing.
This is not a brief semantic PASS. Terminal re-entry, changed semantics,
missing authority or no eligible implementation reviewer remain outside this
route and return to independent decision. No attempt, blocking-round or landing
rule changes.

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
  bounded repair, #8159 parks with a terminal comment.

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

An artifact that accumulates more than four implementation attempts stops
dispatching: force replan-or-park through an independent decision lane (§11)
whose verdict is final. Review, repair, and planning rounds never count toward
this ceiling. An implementation attempt counts only when a pushed head
receives a hosted CI verdict or an exact-head review verdict
(4388/5845981597). Local-only failures, preparation stops, harness or
environment failures, lock refusals and a lane's own tooling defects do not
count; the lane repairs them within the same attempt. Existing counts are
recounted under this definition. That is a recount, not a reset: an attempt
that did receive a hosted or review verdict keeps counting. No further dispatch binds to it until that verdict is recorded. This ceiling
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
non-ancestor, missing-finding, and non-fixable predecessors fail closed. The
governing release proof follows `contracts/review-v2.md:126-132`.
For governing install proof, an initial candidate requires `-Scope full`
against the installed baseline; a repair against a governing `BLOCK_FIXABLE`
baseline requires full scope when its diff changes a runtime script.
For a skill/contract/test-only repair, impact scope satisfies the contract's
"prose plan" because its smoke set includes the policy pin and contract
enforcement. Impact and prior-result reuse runs are author-iteration evidence
only, never substitutes for the governing install proof. The author-iteration
battery runs the impact scope: the smoke set (policy pin, contract
enforcement, installer, battery self-test, landing preflight), the changed
tests, the guard discriminators, and every test that reads a changed file,
following code readers transitively and skill, contract and data readers
directly. No baseline, `-Scope full`, or a changed runtime file that no test
reads runs the full battery; a battery change adds its full self-test. In an
impact run a guard-omission mutant or #8102 classifier leg runs only when its
guarded file or the carrier support changed; candidate arms always run. Tests
run fastest first and the battery stops at the first failure that is not
PREEXISTING, naming the rest not run (`-OnFailure all` runs all). A rerun
passes `-PriorResultPath` and reuses passing tests the fix cannot reach;
guard items always run. A failure that reproduces identically on
the installed baseline ends `FAIL_PREEXISTING_ONLY`, which never prints PASS;
the governing review accepts it once each named item has an open issue, and
nothing waits on that issue. The host runs the full battery on the installed
head at most weekly, hidden and never blocking a release; a failure there
files an issue. The selected battery runs once per candidate head, by the author lane,
with its log bound to the exact head; the governing review verifies that log
and re-runs only the tests the diff changed, directly as focused tests, never
through ControllerBattery, ControllerPrecursor or a battery rerun. Heavy
reproduction returns to the host's attributed implementation/verifier lane.
A review report is the report
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

Each cycle, before section 13, collect every open product PR with
`landing-preflight.ps1 -Action Report -MutationDisabled`. Retain each
`velocityLanding` projection, including queued PRs: `PR_ALREADY_ENQUEUED` is
still an operational refusal, never non-hold qualification. Dot-source
`velocity-metrics.ps1` and atomically publish the complete cycle with
`Write-VelocityLandingCapture -Path <container>/.orchestrator/logs/velocity-landing-capture.json
-CycleId <unique-cycle> -StartedAt <UTC-cycle-start> -Reports <Report-results>`.
Pass that same `-CycleId` to section 13; `-LandingCapturePath` optionally selects
the capture. A missing/partial/mismatched cycle or evidence older than five
minutes is UNKNOWN. Only Report performs per-PR external reads; the collector
joins bulk repository/PR/immutable-head facts to this capture. The projection
neither fetches missing adapters nor enqueues, dequeues, lifts, or grants authority.
SKIP is a blocked review outcome. Unknown outcomes fail closed for that PR,
without discarding sibling records. An executing staging deploy does not
replace the latest completed deploy health; completed red remains unhealthy.

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

Incumbent enqueue, repair, and landed-integration actions below are confined to
incumbent-owned scope (section 4), including direct-enqueue fallback. A qualifying
landed-integration obligation for a platform-owned PR goes to platform #367
while ISS-110 is open, then #368, instead of dispatch into its branch. The
platform's refresh-forward path (ISS-079/ISS-142) absorbs it. The complete census
still observes those targets, but never authorizes unrestricted auto-integration
into a platform branch; do not invoke a dispatch path that would mutate one.

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

These reclamation rules exclude platform-owned worktrees and processes even
after idle, park, or merge. Ownership transfer requires section 4's Todd ruling
and register change; rollback follows the separately authorized runbook.

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
  criteria within the current product scope, an attempt-ceiling disposition, a
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

Do not send routine milestone creation, splitting, rescoping, placement,
ordering, issue ranking, or scope tradeoffs within an accepted outcome to Todd.
Agents own those choices under §4. Escalate to Todd only when a tradeoff would
change product priority or accepted product scope. Other legal and external
authority reaches Todd only as a packaged operator action.

The existing Todd-reserved rules are unchanged: platform ownership transfer
(§4), host rotation (§2), rollback (§3), and reclaiming unrecognized worktrees
(§9). Status posts list only open priority or scope questions and packaged
operator actions. They never list process decisions as waiting on Todd.

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
terminal comment. Replacement never resets an attempt count, and counts follow
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
and reports `velocity-report/v1`. It raises only two alarms. Everything else
in the report is diagnostic context that never triggers work or files an issue.
- FLOOR: fewer than two product issues have an agent-owned next step (a live
  lane, running hosted CI, or the unblocked merge queue) while a ready product
  issue is idle or an exact-head PASS product PR is held, continuously for 60
  minutes. Held means ready, non-hold-qualified and covered by a validated
  active merge hold; count each PR once with its hold identities, never as
  ready idle or queue-only flow. Independent live-lane, CI or unblocked-PR
  progress may still flow. Name both idle and held causes and the host action.
  The host fixes it the same cycle by
  dispatching, backfilling (§4) or unblocking, and logs `decision-resolved`
  with `velocity:FLOOR` in the note. It needs no retro.
- Live lanes join their canonical routing Issue, attempt, label and worktree,
  retaining live origins beyond seven days and exact relaunch labels. Supply
  positive `-Issue` on every dispatch role. Explicit Issue wins; only absent
  Issue permits a leading positive issue prefix matching this census, and
  `-cN` inherits only one unambiguous prior-seat issue. Unresolved owned lanes
  older than ten minutes are named gaps, never an idle FLOOR cause. The
  eight-hour staleness flag remains diagnostic only. Green open PRs with an
  exact-head live review/repair lane or bound enqueue/landing row flow once;
  without one they are ready idle, regardless of native review status.
  A same-PR, same-repository dequeue at or after a binding row unbinds it;
  a later re-enqueue rebinds. Future rows confer no binding or unbinding.
  A merged product PR flows as landing only with a landed row and no
  deploy-verified row between merge and now, regardless of landed-row write
  order, for less than 24 hours after merge. Terminal
  parks without admitted live re-entry stay in a separate diagnostic bucket;
  uncertain terminal evidence never becomes ready idle.
- DROUGHT: no `kind:product` merge for 48 hours, re-armed every further 48
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
- Until the heartbeat ships in #8222, the host checks `unacted` in each cycle's
  summary (FLOOR 2 hours, DROUGHT 4 hours).
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
- When automation replaces a host duty, remove the redundant routine in the
  same reviewed adoption change after its replacement coverage is exercised.
  Keep manual fallback for unavailable, stale or incomplete evidence, not as
  a parallel routine. Use existing issue/PR and execution evidence to check
  whether the action, wait or failure disappeared; add no report, approval
  stage or delivery gate.
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
