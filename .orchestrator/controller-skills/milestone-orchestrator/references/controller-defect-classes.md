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
Constraint for dispatch prompts: Count every in-body brief repair in model history. Apply milestone-orchestrator section 7's bounded FINAL nonterminal proof route only with completed repair, exact current body/dependencies, full findings, trusted readiness and ordinary admission, followed by a fresh code-history-independent complete exact-head implementation review challenging the whole brief and all findings. This is not a brief semantic PASS. Terminal re-entry, changed semantics, missing authority or no eligible implementation reviewer returns to independent decision; no attempt, blocking-round or landing rule changes.
Structural guard: CONTRACT_AND_REGRESSION; no runtime exception/admission receipt is introduced and no model-history exclusion is weakened. Since v2.103 (4388/6022146271), an exhausted roster falls back only to a reviewer that did not author or repair the exact revision, with disclosure; complete history is retained.
