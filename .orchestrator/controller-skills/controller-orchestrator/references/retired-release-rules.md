# Retired product-loop release rules (milestone-orchestrator v2.115)

Moved verbatim on 2026-10-18 for reference only. They are NOT this thread's
release process; the release process is in `../SKILL.md` and the dev
container `AGENTS.md`. Use them when deciding which battery or review proof a
change needs; do not reinstate packets, batches or receipt-gated installs.

Every controller release, Todd-authored or controller-authored, takes one
governing review scoped to its change and installs on PASS; there is no packet
lifecycle and no weekly release train. A controller P0 is any landing-gate
defect that refuses a landing-authority-complete PR (§8), any breaker-repair
refusal, and any pipeline breaker on the controller itself; a controller P0
ships out of band by default without a Todd ruling: bounded repair, full
runtime battery, one governing review, install. A release identifier is never
burned on a module whose prerequisite is unmet; such work waits at filing on
that prerequisite as a native blocker, and an implementation of a Todd ruling
is never parked (§15).

Batch releases ([Todd's #4388 batch ruling](https://github.com/chase-sets/chase-sets/issues/4388#issuecomment-6169900446),
codified as a member of batch 1, #9614): while the ruling is in force, the
preceding paragraph's no-packet-lifecycle clause and the re-anchor each install
forces on every other in-flight candidate are suspended, and controller
releases, Todd-authored or controller-authored, batch. A candidate joins a
batch only if it has a strict governing `controller-review-receipt/v1` PASS at
its own head before the batch is cut and merges onto the installed baseline
without conflict alongside the other members; a candidate that is red,
unreviewed, under review at the cut, or conflicting goes to the next batch and
never holds the current one. The combined head gets one `-Scope full` battery,
with CI-sourced reuse unchanged, and one governing review over the merge
result, any conflict resolutions, any repairs and any member diff no receipt
already covers; on PASS it installs once through
`install-controller-skills.ps1 -ReviewedCommit`. Members are not re-anchored,
re-batteried or re-reviewed individually. Each batch has one tracking
controller issue naming its member issues and heads; that issue is the receipt
identity, and each member gets its own installed/landed row. Unchanged:
exact-head receipts, the strict governing PASS, the clean tracked-tree gate,
guards that always run locally, the PREEXISTING baseline rule (Todd
4388/6167918688) and the controller P0 out-of-band path; no gate is bypassed
and no attempt is reset. The ruling ends when Todd rules battery cost fixed or
when #189's exit gate makes the hosted battery the native governing proof,
whichever comes first; the host records the end on #4388.

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
enforcement. Impact-scope and local-prior reuse are author-iteration evidence
only, never substitutes for the governing install proof; a local prior that
carries `ci:` rows is local-prior reuse.

CI-sourced reuse (Todd 4388/6112638067, #9373) may serve a governing install
proof, initial or repair, at `-Scope full` only. Run
`controller-release-battery.ps1 -Scope full -PriorResultPath <final.json>` with
the `controller-battery-result` final.json of a completed hosted
`chase-sets/chase-sets-controller` run of the exact candidate head, whatever
its conclusion; per-item rows govern. The battery lends only fresh `test:*`
PASS rows with equal arguments that the diff cannot reach, never a CI row of
another `scope.kind`. Everything else runs locally: FAIL, LOCAL_ONLY,
restricted and not-hermetic items, the guards
(`direct:fail-closed-guard-evidence` and every `discriminator:*`, under every
prior), each `-NoReuseIdentity` item and anything the battery declines to
lend. No item turns from FAIL or LOCAL_ONLY into PASS by reuse; such items get
verdicts only from local execution. The governing review checks:

- executed + reused = satisfied = required;
- the log's `REUSE ... source=ci:<runId>` line;
- `provenance.source = ci:<runId>` on every reused row, for a completed run on
  the exact reviewed head;
- an empty diff since that run's `controllerHead`;
- every guard/open safeguard identity executed locally;
- no reuse after the second occurrence.

Safeguard: record distinct local/weekly failures of CI-reused items on
CI-passed heads in #189 `Bug`s titled
`[controller] CI reuse safeguard: <identity>`. While open, pass the identity
in `-NoReuseIdentity` (one `;`-separated string) and verify local execution.
A second occurrence ends governing CI reuse (`reusedCount = 0`), even for the
same identity/Bug; duplicates count once. Closure does not undo termination;
only a new Todd ruling reinstates it. This rule lasts until #189's exit gate
makes the hosted battery the native governing proof.

The author-iteration battery runs the impact scope: the smoke set (policy pin,
contract enforcement, installer, battery self-test, landing preflight), the changed
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
