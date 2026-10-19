# Reviewed controller defect constraints

This static supplement ships with the reviewed controller. It augments the
machine-maintained defect/stall ledger pair without replacing either ledger.

## unattributed-nested-model-dispatch (first bitten 2026-10-01, last updated 2026-10-01)
Defect: a planning lane treats an adapter failure as permission to launch its own unrecorded native model reviewer, bypassing attribution and model-history exclusion.
Territory: planning-repair lanes, independent-review handoffs, collaboration adapter failure, native model CLI fallback and review prompts.
Territory globs: .orchestrator/contracts/planning-repair-v1.md, .orchestrator/contracts/review-v2.md, .orchestrator/dispatch-lane.ps1
Occurrences: #8450 planning repair 8450-replan-r1 after unsupported_encrypted_delegation; FINAL 8450-review-authority-decision-r1 Q1/Q4 deemed the bypass non-governing.
Guard issue: #8463.
Constraint for dispatch prompts: A lane must not launch model CLIs or subprocess reviewers itself; any required independent review returns to the host for a canonical attributed dispatch after full artifact author/repair-history eligibility checks, and output from a bypass is non-governing evidence, never review or admission authority. Report PENDING_HOST_REVIEW after an adapter failure, not a verdict. Cross-references: review-probe-live-provider-credential-inheritance and review-isolation-opt-in-by-default concern provider isolation, not this root cause.
Structural guard: CONTRACT_AND_REGRESSION; planning/review contract injection and bypass-negative/host-positive authority tests. No sandbox CLI block or new launcher is claimed.

## brief-repair-exhausts-independent-reviewers (first bitten 2026-10-01, last updated 2026-10-01)
Defect: direct in-body brief repairs and protected-author core repair can exhaust the admitted independent brief-reviewer roster; another sweep deadlocks or launders model history.
Territory: nonterminal planning-repair, brief review, artifact author/repair-history exclusions and independent implementation review.
Territory globs: .orchestrator/contracts/planning-repair-v1.md, .orchestrator/contracts/review-v2.md, .orchestrator/controller-skills/milestone-orchestrator/SKILL.md, .orchestrator/controller-skills/model-routing/SKILL.md
Occurrences: FINAL brief-sweep2-authority-decision-r1 Q3, #8452/#8453/#8464; #8450 proof-route precedent.
Guard issue: #8466.
Constraint for dispatch prompts: Count every in-body brief repair in model history. Apply milestone-orchestrator section 7's bounded FINAL nonterminal proof route only with completed repair, exact current body/dependencies, full findings, trusted readiness and ordinary admission, followed by a fresh-session complete exact-head implementation review on the row's policy slot challenging the whole brief and all findings. This is not a brief semantic PASS. Terminal re-entry, changed semantics, missing authority or no eligible implementation reviewer returns to independent decision; no attempt, blocking-round or landing rule changes.
Structural guard: CONTRACT_AND_REGRESSION; no runtime exception/admission receipt is introduced. Reviews use the row's policy slot regardless of authorship (4388/6229141245); independence is a fresh lane and session, never self-review, with disclosure; complete history is retained.

## claude-foreground-gate-exceeds-tool-limit (first bitten 2026-10-15, last updated 2026-10-15)
Defect: tool timeout auto-backgrounds finite work; stopping loses verification (#6005 rejects).
Territory: Claude launcher/Bash/PowerShell.
Territory globs: .orchestrator/dispatch-lane.ps1, .orchestrator/dispatch-claude-stream-audit.ps1
Occurrences: four 2026-10-15 incidents recorded in #9712: 9662-impl-g1 b7vkwn15o, 9670-impl-g1 byrzz1l3m, 9659-replan-r1 b5jk33uy6, 9585-impl-g1 b7g04cpkn.
Guard issue: #9712.
Constraint for dispatch prompts: Claude-only finite envelope; gates omit timeouts; narrow reads/polls pre-call. No auto-backgrounding. Keep #6005 active/killed/stopped/malformed rejection, native >600s completion/incident rejection proof, slot/product budgets.
Overlapping constraints: `claude-background-task-dies-on-session-exit`: no Monitor/ScheduleWakeup/Cron, long watchers or sleeping polls; terminal verification/commit/push/PR updates stay foreground. `dispatch-wrapper-nonzero-exit-is-not-lane-death`: lane evidence, not wrapper status/report prose, governs recovery. `claude-detached-task-survives-forced-termination`: no kill/relaunch/cleanup added. `windows-powershell5-utf8-launcher-parse`: native PS7 hosting retained. `heavy-admission-misses-browser-probe-script-alias`: browser/bootstrap/direct/nested-pnpm admission unchanged. `unattributed-nested-model-dispatch`: host-only independent review after full author/repair-history checks, no nested fallback.
Structural guard: pending reviewed install and exercised proof, not SHIPPED.
