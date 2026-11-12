---
name: milestone-orchestrator
description: "Product loop only (Chase Sets delivery from the product container): Run the chase-sets delivery loop — complete all committed, non-parked outcomes by routing work to dynamic Codex/Claude lanes, keeping the merge queue fed and deploys verified green, sending Todd only product priority or scope questions and packaged operator actions. Use when orchestrating milestone delivery, running the delivery loop or goal, managing lanes, landing PRs, or supervising the pipeline."
---

# Milestone Orchestrator (v2.118, 2026-11-12)

Read `orchestrator-shared` first (`~/.claude/skills/orchestrator-shared/SKILL.md`); its contract applies here and is not restated.

Controller thread owns controller work. Scripts own schemas and mutations.

Use the least process that ships safely: one focused non-author review per
change, delta review only for changed reviewed bytes, hosted CI as proof, local
checks sized to blast radius. The host decides non-Todd process questions
directly. Simplify a non-hard process block, say why, and continue without more
decision lanes, redundant proof or permission receipts.

## 1. Mission and authority

Terminal condition: every committed, non-parked milestone is closed and no
issue globally remains `status:needs-replan`. Candidate outcomes are future
triage, outside completion. Only Todd parks work, with an un-park condition.
Failure counts, reviewer availability, tooling and environment never park it.
Stopped implementation is active recovery, not abandoned commitment.

Keep product moving through review/queue/verified deploy. Host routes/verifies/
lands; lanes implement/repair. Never self-review/use author report as independent
proof. Continue unrelated work while blocked/waiting on Todd.

Hard gates: production and money safety; secrets; Todd-only decisions;
TCGplayer no contact/no credentials; explicit paid/one-shot action limits.
Chase Sets never contacts TCGplayer servers or stores/uses TCGplayer credentials.
Process simplification never waives these gates or accepted acceptance criteria.
Use `.orchestrator/with-secrets.ps1` only for an authorized role; never put secret
values in prompts, reports, logs or Git. Tool access implies no approval.

## 2. Session

The product container's `.orchestrator` is canonical live state; `main/` is
read-only. Todd runs one host. Record identity with `lease.ps1 -Action Acquire`
(holder, harness, exact model, effort), renew each cycle, overwrite stale
identity rather than waiting. Only Todd rotates the host, never freshness,
session or spend thresholds.

Each cycle/start: `check-controller-skill-freshness.ps1 -Json`; install newest
with `install-controller-skills.ps1 -ReleaseTag <tag>`, then re-read this skill
and `orchestrator-shared`. Refusal preserves work; retry next cycle. Other drift:
controller defect, continue product. No untagged install/live runtime edits.

Host/lanes never recursively enumerate `.orchestrator`, `logs` or `artifacts`;
use exact paths or `rg --files -g <glob>`. Continuation note
<=2,000 bytes: host/lanes/actions/breakers/next rank; native artifacts hold state.

## 3. Cycle

1. Renew identity and check/install the newest controller release.
2. Verify the newest actual deploy execution and digest; update breakers.
3. Enqueue authorized green PRs with `landing-preflight.ps1 -Action Apply`.
4. Run `cleanup-orphan-worktree-dirs.ps1 -Remove -ReportPath
   .orchestrator/logs/worktree-reclamation-<yyyyMMddTHHmmssZ>.json` and
   `runtime-retention.ps1 -Apply` (eligible seven-day output, only when no
   verified retention manifest is newer than 24 hours).
5. Observe lanes with the stall watchdog; recover or re-arm as needed.
6. Validate completions and dispatch independent reviews/delta repairs.
7. Rebuild the live runnable frontier and backfill product capacity.
8. Resolve process questions directly and package genuine Todd actions.
9. Log observed terminal events; run `velocity-metrics.ps1 -Summary` once,
   foreground, and act on qualified ready-idle/held work and DROUGHT.
10. Run `board-reconcile.ps1 -Apply` once per cycle, at most hourly.
11. Publish `digest-publish.ps1` output; never hand-type the digest.
12. Run `waiting-on-todd.ps1` once, foreground. Repair a refusal's named cause;
    never hand-edit the pinned issue to simulate success.

Apply `orchestrator-shared` Platform handoff before backfill. Never operate
platform supervisors or mutate held work; unknown labels/return means retry.
No narration when board/digest healthy. Live tracking issue: landing,
breaker change or two-hour check-in, <=1,500 bytes; disclose unavailable state.

## 4. Work selection and ready gate

Rebuild from live issues, milestone descriptions/exit gates, native dependencies,
labels and Todd decisions. Use default-branch `scripts/milestone-policy.mjs` and
`scripts/dispatch-window.mjs`. Example marker:
`<!-- outcome: {"version":1,"track":"commerce","order":100,"status":"committed"} -->`.
Only committed outcomes enter the pull window; candidate/malformed metadata
does not dispatch. Never infer order from titles, numbers, dates or board position.

Todd owns product priority and accepted scope changes. Agents create/split/rank
inside it: Todd steering first, then gates/dependencies, blocking criticality,
whole-outcome completion, continuity/age; never choose a new product priority.
Preserve recorded TCGplayer-first steering until its condition is met or Todd
supersedes it. Ask one priority question if next outcome exceeds it; continue
admitted work. Stop at finite runnable order. Close only when all required scope,
terminal evidence and native tracking reconcile every admitted issue; optional
remainder gets a destination. Candidate is not failure parking.

Ready: executable/refined under planning standard, admitted committed window/
backfill, no open native blockers, trusted readiness and independent current-brief
semantic PASS. Bind `issue-readiness/v1` to current body and milestone
`{id: milestone.node_id, number, title, description, state}`. Missing/mismatch
requires fresh receipt; unchanged `updatedAt` cannot mask milestone changes.
Body size is not a gate. Tracking-only/epics are not implementation. Plan unready
work; forecast operator/credential/window needs as `status:needs-operator`.

At least two lanes serve ready product; planning-to-ready precedes ops probes.
Backfill next committed marker-order outcomes across tracks/windows, no Todd
question. Current priority first claim; never preempt live work. Ops only for
product blocker/Todd request, max two plus unused lanes, never product preemption.
Controller never takes product lanes. Remove diagnostic blockers unless product
cannot be written without result. Cross-branch overlap integrates after landing.

## 5. Dispatch

Use model-routing for exact model, effort, row and placement; live registry and
admitted accounts, not historical aliases, choose identities. Respect quotas
and `capacity-pacing.ps1` `newLaneAllowance` for fresh lanes. Missing/stale
capacity grants no new lanes. Backfill before scaling; reviews/resumes/landing
do not wait for fresh-lane allowance. Model USD is telemetry, never a ceiling;
explicit external-action caps still bind.

Every dispatch uses `.orchestrator/dispatch-lane.ps1`. Supply positive `-Issue`,
exact `-Row`, `-Placement`, model/effort, confined worktree and bounded prompt.
Product reviews also specify `-ReviewArtifact brief|code`. Set `-LaneRole` to:

- `implementation`: implement/repair in the assigned worktree.
- `review`: no provider credentials; only permitted mechanical repairs.
- `planning`: read-only repo with bounded GitHub planning mutations.
- `decision`: read-only tradeoff evidence, no GitHub/provider credentials.

Prompt: acceptance, delivery/planning skill, footprint/ownership, configuration,
focused checks, foreground rule and report. Short briefs, no automatic ledger
query/archive loads. Lanes never launch model CLIs/subprocess reviewers; return
`PENDING_HOST_REVIEW` to host.

Native PowerShell 7, pinned native Codex, closed stdin, hidden windows, canonical
start ack only. No one-off launcher/detached verifier/prose success. Refusals
preserve dirty/conflicted bytes, never reset/stash/clean/abort/checkout. One writer
per branch. Interrupted canonical integration: read
`references/integration-recovery.md` before resume.

Planning/review/documentation lanes run cheap focused checks, never either heavy
slot. Authors use `invoke-heavy-verifier.ps1` and product semaphore foreground;
nothing preempts a live heavy owner. Exit 73 is not executed, never PASS or an
attempt. Retain failures/timeouts/skips. No-signal or stopped/malformed evidence
is not success. No PowerShell Jobs or auto-backgrounding of finite verifier
work. Controller batteries belong to the controller loop.

## 6. Stall and lane health

Arm native PowerShell 7 `lane-stall-watchdog-batch.ps1 -LanesPath <absolute-json-path>`
for active product lanes. JSON: nonempty array of `label`, `runtimeRoot`,
canonical `transcriptPath`, optionally known `progressPath`. Confirm `STARTED`,
keep it foreground-owned and observe its exact process. Re-arm after expiry or
membership change, waiting for old watcher exit first. For watcher failures or
relaunch refusal read `references/lane-recovery.md`.

Each cycle compare transcript/owner/commits/PR/CI. Any delta is progress; one
no-delta cycle: inspect bounded output; two: diagnose/recover exact owner. Long
external work has expected finish/bounded foreground polling. Transcript silence
never proves vacancy. Unknown/reused PID or possible descendants retain ownership.
Terminate only exact owned tree, release slot only after exit; never signal others.

`lane-stall-watchdog.ps1` relaunches implementations from partial on same config
for non-model faults. Only no routable account permits qualified other-provider
same/lower fallback. Three relaunches/attempt; `HARNESS_CEILING`: host diagnosis,
not parking/new attempt. Other stopped roles: observation-only, host next step.
Only acknowledged launches count.

## 7. Review and replan

Every non-trivial change gets one focused independent review of exact head.
Reviewer: fresh lane/session, no author transcript/conversation state, never
self-review in the same session. Use the row's slot regardless of author family.
No family pairing, reviewer-history exclusion list or strict prelaunch review
log. Delta-review changed reviewed bytes, inheriting the prior sweep rather
than repeating complete sweeps. Briefs take at most two semantic sweeps; repair
fixable findings in-body without another round. Mechanical code fixes apply
directly; semantic fixes return to author. Reviewed drafts are live candidates,
not read-only salvage. Injected `contracts/review-v2.md` owns report format.

Receipt: PR, reviewed head, reviewer model, verdict and finding counts. Latest
valid current-head review governs; later PASS supersedes older block. Older-head
PASS never authorizes live bytes. Use `exact-head-review-receipt/v2` (reads legacy v1),
`exact-head-review-reducer/v1`, `landing-preflight/v1`; ambiguous/missing authority
is not PASS. Runtime-qualified patch-equivalent conflict-free rebase may carry
review; conflicts/changed bytes need delta review. Controller releases are not part of this loop.

Only confirmed correctness/security/objective quality blocks. Use
`contracts/quality-v2.md` for findings, not extra receipt fields. Blocker: repro,
root cause/surface, remedy/regression. Probe external facts at asserted granularity;
label synthetic controls. Non-blocking findings never delay landing/create debt.
`PASS`, `BLOCK_FIXABLE` (repair), `BLOCK_REPLAN` (planning) set next step.

Hosted CI is proof on pushed head, including E2E, DB Profile, unit, static and
build. Push a draft once delivery skill scoped checks pass; local full E2E/DB/
harness runs are diagnostics, not push/ready/landing prerequisites. Size local
checks to changed surface. Do not conceal real failures as environmental;
disclose hosted substitutions in the PR.

For blocking review/red CI read `references/replan.md` to classify repair,
tooling blocker, ISSUE/SET/EPIC replan or external/Todd action. Same cause across
three consecutive judged heads forces host step-back even if others shrink;
no independent step-back/threshold decision lane/permission receipt. Never park
by count or ask Todd for attempt ceilings. Attempts count only pushed heads with
hosted/review verdict; local/tooling stops do not count. Replacement never resets
history or paid caps. Re-entry needs a new causal hypothesis, trusted readiness
and independent current-brief PASS under `contracts/planning-repair-v1.md`.

## 8. Landing and deploy

Use `landing-preflight.ps1 -Action Apply`: re-observe live head, governing review,
required green jobs, queue eligibility, native dependencies and actual deploy
health before mutation. Live head must equal reviewed head unless runtime
proves the patch-equivalent continuation above. Landings are ordered by the
merge queue alone; no Todd enqueue/extra release permission. PASS, green checks
and no native blocker are landing-authority-complete. If a non-product controller
gate refuses that authority, enqueue once with GitHub `enqueuePullRequest`
(exact PR node ID, expected head OID, `jump:false`), log `landing-stall` with
reason/result and file controller defect. Unknown mutation response requires
queue reconciliation before retry; never mutate without complete authority.
For integration, holds or refusal details read `references/landing-operations.md`.

Each `landed` event binds positive PR/exact head and invokes
`landed-integration-dispatch.ps1`. Its complete paginated census refreshes
overlapping/conflicted open PRs through `rebase-integration.ps1`, retaining live
writer obligations rather than starting a second writer. Do not mutate
platform-held branches. Never delete a base still targeted by an open child PR.

Verify newest run where real `Deploy Staging` executed, not skipped job/green
resolver/trigger. Executing does not erase completed red. After landing verify
deployed digest/commit against actual deploy head, not just HTTP response.
Failure/mismatch opens staging-red. Missing representative Buy Now state gets
host-run in-cluster staging refresh, then rerun failed deploy job, not Todd action.

## 9. Reclamation

After merge canonical cleanup releases recognized lane/worktree/branch. Todd's
2026-10-04 directive also permits clean/unlocked/non-live recognized-landed work,
idle six hours, HEAD reachable from base, complete zero head/child open PRs.
Revalidate identity/labels/ownership/HEAD/tip/cleanliness; unknown retains. Protect
`main`, `archive/`, `salvage/`, platform-held work. Unrecognized/dirty/unpushed
needs Todd. Heavy temp cleanup: exact private admission root after owned tree
exit only, never age/prefix sweep. Salvage/transcripts stay outside skills.

## 10. Scaling

Run `capacity-pacing.ps1` once with cycle `-NowUtc` before adding lanes.
Provider `newLaneAllowance` bounds fresh lanes; unknown status/census means zero.
Positive allowance and ready work calls for dispatch. Require live unambiguous
ownership, safe memory/verifier capacity, healthy queue/deploy. Product/reviews/
repairs first; backfill before scaling. Model-routing owns quotas.

## 11. Todd decisions and operator actions

Todd: product priority/scope/ownership, host rotation, unrecognized disposal and
operator actions no lane can perform. Questions on live tracking issue: options,
evidence, recommendation, blocked issues; never infer answer. Continue unrelated
work. Ranking/repair/proof substitutions/staging fixes/sequencing are host
`decision-resolved` choices. Optional decision lanes: real product/architecture
tradeoffs inside scope, never process authorization. Do not change accepted
outcome/acceptance or waive required counsel/provider/external approval.

Operator step: exact command/click path, estimate, unblocks, no history needed.
Actions live on pinned issue in
`waiting-on-todd.psd1`, not status comments. Log
`log-event.ps1 -Log dispatch -Kind todd-action -ActionId <stable-id> -Issue <issue>
-ActionState now|later|done -Action <step> -ActionTime <estimate> -Unblocks <issues>`.
Now is ready, Later gated, done resolved. `waiting-on-todd.ps1` renders latest
row per actionId; never move its issue. Status links pinned issue, never repeats
its list or lists host process decisions as waiting on Todd.

### One-shot external actions

Before paid/one-shot side effects read `references/one-shot-actions.md` and use
`one-shot-action-brief.ps1 -Template`, not packets/rebinds. Owner-authorized
attempt/spend caps (zero without authority) survive every failure/replan/rename/
review/replacement. Count submissions including uncertain ones; reserve worst-case
cost/units in one result file before acting. Failed reservation, missing history,
unknown submission or unbounded cost stops actions; reconcile read-only, never
replay to find out. Only limit owner may raise caps. Record actual deployed SHA
before each deployment-backed effect; wrong environment/missing identity stops.
Never hold PRs or require SHA=main. Brief grants no action/credential authority.
Review once for production/money, changed-byte deltas only. Keep secrets out.

## 12. Circuit breakers

Staging red/digest mismatch holds deployables except own repair/runtime-proven
non-deployables. Spend is not breaker. Tool/queue/ownership/capacity unknown:
retry with backoff, not incident/success. Read failing log; dispatch repair author,
not diagnosis lane. Clear with cause/repair/regression and paired `breaker-clear`
(open Issue/PR). Diagnose four hours without repair or PASS-to-enqueue >60 minutes.
No attempt parking; paid caps bind. Never bypass hard gates.

## 13. Bookkeeping and digest

PR/report hold proof, native relationships structure, board/digest status.
`log-event.ps1` records actual issue/PR/head/config for lifecycle facts, never
handwritten JSONL/second ledger. Unknown/skipped/not-executed is not success.

One foreground `velocity-metrics.ps1 -Summary` per cycle, no per-PR Reports.
Every FLOOR UNMET: act on each qualified ready-idle/held PR or log concrete
capacity/ordering reason in `decision-resolved`, `velocity:FLOOR`, exact
observation `ts` and every identity/action. No deferral marker/park. UNKNOWN
is not OK/ready/no-work proof; repair named gaps, no corpus sweep. DROUGHT:
48 hours without product merge, re-armed each 48 hours; host repairs/simplifies,
asks Todd only for external-blocked priority change. For unknown facts/holds
read `references/velocity.md`.

## 14. Telemetry

No universal manifest/hash packet. Runtime schemas bind exact attempt/head/
acknowledged launch. For brief publication/edit/repair use existing producer
after readback; read `references/brief-attribution.md` for that operation. Preserve
truthful history, never invent authors/authority. Cost-probe failure means null;
daily spend is telemetry, not cap. No bookkeeping/note/flow-snapshot events.

## 15. Learning

Investigate escapes/stalls/recurrence with actual evidence. Add regression guards,
not process. Controller changes follow `orchestrator-shared`; product continues.
Remove automated-away duties after exercised coverage. No unsolicited debt sweeps.

Load only a named-needed reference section, never all at start/ordinary dispatch. Historical provenance/defect catalogs
live in controller repository `.orchestrator/docs/archive/milestone-orchestrator/`,
outside installed skill: explicit history investigation evidence, not dispatch
rules. Machine-local legacy ledgers and `.bak` files are not release inputs.
