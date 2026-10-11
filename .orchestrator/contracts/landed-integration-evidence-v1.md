# Completed rebase evidence

## Census preflight

`landed-integration-dispatch.ps1` first validates the complete census and plans
every observed PR. Only after all target dispositions are closed may it publish
an obligation, acceptance, terminal or launch. Its content-addressed
`integration-plan-<sha256>.json` records `landed-integration-plan/v1`, positive
`landedPr`, exact `landedHead` and `newBase`, and `targets` in PR-number order.
Each target has only `pr`, `head`, `branch`, nullable `worktree`, nullable
`reason`, and `action`. Reasons retain INTERSECTING/DIRTY/CONFLICTING. Actions
are LANDED_PR, NOT_REQUIRED, DUPLICATE_SKIPPED, HANDOFF, LAUNCH,
MISSING_WORKTREE, CONTROLLER_ADMISSION_REQUIRED, PLATFORM_HANDOFF_REQUIRED,
OWNERSHIP_UNKNOWN, TERMINAL_AUTHORITY_STOP, AUTHORITY_UNKNOWN or RETAINED_START;
an unclassified target defaults to INDETERMINATE and refuses the entire apply.
The plan records observation, never terminal authority, and is not an input
to replay. A fresh invocation always recollects and validates the census.

MISSING_WORKTREE retains that complete plan, then returns the named
`CENSUS_UNKNOWN_WORKTREE_<pr>` refusal with no mutation rows or launches.
Controller-file targets never enter the product launcher or no-owner claim;
the host retains one-controller-author admission. Platform ownership is derived
from the canonical register and complete native PR/closing-issue observations,
not a remembered milestone list. After LANDED_PR and NOT_REQUIRED precedence,
any registered platform PR milestone, same-repository owner milestone, or owner
in a registered platform repository yields PLATFORM_HANDOFF_REQUIRED before
holder lookup, terminal admission, retained recovery, or any apply effect.
CLOSED owners count, multiple owners are allowed, and disagreement cannot
revoke a positive deferral. Cross-repository milestone numbers do not match
local milestone scopes; executor register scopes are not repository scopes.
Only a complete negative resolves to the register's mandatory incumbent default,
which supplies no admission authority and bypasses none of the later gates.

Ownership collection exhausts 100-node pages, validates nested domains and
unique repository/issue identities, and reconciles totals, cursors and two
complete observations of the owner set. Missing, partial, capped, moving,
unreadable or malformed ownership (even a partial positive) is OWNERSHIP_UNKNOWN.
An initially scoped unknown retains the full six-field-target plan, then refuses
the whole run with `CENSUS_UNKNOWN_OWNERSHIP_<pr>` before any apply effects.
Globally unreadable census/register input refuses without claiming a full plan.
Before each apply action, the dispatcher rereads native head, branch, PR milestone,
the full owner set, and exact register bytes; drift or unreadability returns the
same per-PR refusal before that action's effects. Earlier valid effects cannot
be undone by later drift. Direct `-FixturePath` retains its register/owner bypass;
production ownership controls use `-GraphFixturePath`.

Platform targets remain owed to the existing host handoff in skill section 8:
`todd-skelton/orchestration-platform#367` while ISS-110 is open, then #368. The
host supplies target/landed identities and native/register evidence. The result
remains only `{pr, action}`; no destination field, owed/ack record, completion
or terminal skip is created by deferral, including on repeated observations.
Neither controller nor platform deferral is a terminal skip. Once authoritative state
changes, a fresh plan may process still-owed targets. A valid terminal without
owed/ack residue suppresses another launch or obligation even if the branch
still has a live owner. Owed/ack residue continues to reconcile first.

The production collector, direct synthetic census, pending owed/ack/start
records and terminal history are the preflight entry surfaces. Unknown keys,
invalid integer domains and invalid timestamps fail closed. Structurally
proven legacy non-PR review rows retain the existing reducer quarantine;
ambiguous exact-head identity remains unknown, not absent source PASS.
Production worktree resolution validates the canonical root and attached
branch; a new launch also requires the observed exact head and a clean tree
before apply. The launcher still revalidates admission at the mutation boundary.

## Completion

The implementation and closed schemas are owned by
`landed-integration-evidence.psm1`. Completion acknowledges an integration
obligation. It supplies no source PASS, continuation, CI or landing authority.
Conflict completion always produces `REVIEW_REQUIRED`.

The unchanged ordered `landed-integration-owed/v1` JSON supplies the obligation
identity. Its worktree spelling and serialization remain immutable. New record
identities hash recursively key-sorted compact UTF-8 JSON; byte identities hash
the exact retained UTF-8 or native reflog bytes. Duplicate and extra object keys
are invalid. References use SHA-256, commits/trees use full Git SHA-1 identities,
process IDs and PRs are positive supported integers, and timestamps are zoned.
Git reflog timestamps have native second precision; the retained before-log
prefix independently establishes that capture preceded the native transition.

| Retained phase | Producer and authority | Next transition |
|---|---|---|
| Pending owed-v1 | Existing landed census | Prelaunch capture or no-owner claim |
| Prelaunch start-v1 | Exact implementation launcher, null child pair | Child publication; never completion by itself |
| Actual start-v1 | Actual implementation child tree, published PID/start pair; O ancestor of predecessor | Native rebase start, conflict or finish |
| Conflict-v1 | Rebase entry retains native orig-head, onto and head-name tied to start identity | Conflict resolution under the same owner |
| Completion-v1, OWNER_RELEASE | Exact live launcher after child exit; unique start, native logs/objects, attached clean result and remote result | Ack-v3 |
| Completion-v1, PRODUCER_ADOPTION | Current producer under existing before/after no-owner census; distinct historical execution owner | Ack-v3 |
| Ack-v3 | Consumer cross-validates completion and all original owed fields | Producer appends one landed-target terminal |
| Terminal with owed/ack residue | Both readers validate exact result or Git-proven descendant | After exactly one terminal, delete unchanged exact owed bytes and the matching acknowledgement |
| Terminal without owed or ack | Completed obligation requires no further acknowledgement validation | Steady state; ordinary later branch rebases do not reopen the obligation |

The prelaunch and actual-start records occupy separate immutable
`integration-rebase-*` paths, outside the owed glob. Native log and recovery
source bytes remain in content-addressed `integration-rebase-bytes-*.bin`
files. CreateNew plus durable flush publishes new records; different existing
content refuses. The existing trusted runtime storage is the trust boundary;
hashes are not administrator-resistant signatures.

Prospective capture occurs automatically at dispatch and at rebase entry,
including an obligation published after launch. A start first observed at an
already-rebased result is invalid. Release authenticates the actual caller,
not caller-supplied owner fields. Review/planning/observer, wrong launch,
wrong/reused PID/start, missing child and multiple owners are non-authority.

Recovery input is a closed object with `obligationIdentity`,
`executionLaunchId`, `resultHead`, `resultTree`, and `evidence`. The five
references are the executor's watchdog, canonical dispatch log, exact owed
acceptance, original prompt and native command transcript. Each reference has
`path`, `sha256` and `recordIdentity`. For watchdog and acceptance,
`recordIdentity` is the canonical object hash; for routing it is the one exact
matching closed routing row hash; for prompt and transcript it equals the
whole-file byte hash. Paths are original direct children of that runtime root.
Referenced bytes are retained before completion. Replay reads those retained
bytes rather than a subsequently changed watchdog or dispatch log.

Recovery validates routing/acceptance/executor joins and actual conflict,
continue, exact lease publication and result probe command outputs, then checks
the native predecessor-to-result rebase transition and current remote under
the current claim. It never invokes rebase or push, backdates a start, or treats
report/PASS/watchdog/acceptance alone as completion. An already-existing valid
completion can replay without historical PID liveness.

Both readers retain ack-v2's exact/descendant behavior and read ack-v3 before
the ordinary original-head ancestry guard. Conflicting versions, missing
objects, nonzero or ambiguous Git output, reset/unrelated movement, missing or
crossed evidence, unfinished rebase and unknown publication fail closed.
Refusal retains source, owed and acknowledgements. Append failure retains the
acknowledgement for retry. Acceptance without acknowledgement remains pending.

The R3 suite executes the candidate's production callers against isolated Git
repositories/bare remotes. It also executes the immutable installed baseline
for the legacy failure and retains raw native provenance. Existing rebase and
landing suites govern conflict-free continuation and exact review/CI rules.


## Automatic dispatch and retained starts

The existing producer selects exactly codex / gpt-6-astra / high / row 7 /
override-Todd for a new integration. The launcher independently enforces this
at its native boundary. There is no lower-tier fallback; a missing eligible
executable or unknown target refuses before owner or child publication.

`integration-dispatch-request/v1` is closed: schemaVersion, requestIdentity,
repository, pr, landedPr, landedHead, head, newBase, branch, worktree, label,
sourceIdentity, sourceHead, runtimeRoot and historyPath. All identities use
full hashes, bounded positive PRs and fully qualified paths. The request path
is the direct runtime child `integration-request-<label>.json`; its prompt is
`<label>.prompt.txt`, and history is a direct child of that same runtime.
Source identity is an exact PASS identity or ABSENT_REVIEW_REQUIRED. The
source head is present only with a source PASS. Duplicate keys are rejected.
CreateNew publication preserves different existing bytes as a conflict.

Admission proves clean attached canonical worktree/root/ref/HEAD, exact PR
repository/branch/head and origin branch head equality, and fully qualified
origin/main, remote main and GitHub main equality. Native nonzero exits,
missing refs, ambiguous branch attachment, unpublished changes and stale API
observations refuse with observed identities and an author-reconciliation
action. The launcher repeats target checks before publication and rejects a
request changed since admission. Prompt, helper and watchdog never obtain
authority from command text in a transcript or report.

The helper argument builder includes Pr, ReviewedHead, NewBase,
SourcePassReceiptIdentity, IntegrationLane (the actual dispatch label),
Worktree, RuntimeRoot and HistoryPath. SourcePassReviewedHead is conditional.
PowerShell is noninteractive; native Git disables credential prompts and both
editors. Stable-patch one/two-hop continuation, absent-PASS REVIEW_REQUIRED,
conflicting-hunk DELTA and exact-new-head CI remain unchanged.

Only integration launches emit watchdog-lane/v3, which adds one recursively
closed integrationRequest to v2. Both watchdog and completed-rebase readers
validate that request before creating a local v2 reader view. Retained bytes
and record identities remain v3. Mechanical relaunch carries a new label and
request identity under the same fixed tuple, checks current target authority,
and supplies the complete helper invocation for that new label. v1/v2
watchdogs and start-ack/v1 remain readable under their original contracts.

A retained start is checked before any fresh producer launch. The old
request hash remains its key; a new request version does not evade it.
The reader joins the exact ack, watchdog, prompt/request, unique canonical
routing row, native process/start/descendant observations, native exit and
complete transcript. Unknown or crossed state returns RETAINED_START_PENDING.
An exact matching start returns RETAINED_STARTED without inventing completion.
A mismatching start may produce EXITED_START_MISMATCH only after proven exit0,
a complete parameter-binding-stop transcript with no other executable effects,
and unchanged clean native HEAD/ref/reflogs since launch. Transcript commands
are parsed as data and never evaluated. Potential PID reuse/descendants,
unsupported tools/commands, missing output or later Git movement remain pending.

The immutable closed integration-start-observation/v1 records requestIdentity,
launchId, requestedHead, actualStartHead, observedHead, the actual old
harness/model/effort/row/placement, status, nativeExitCode, integrationResult=false,
observedAt, ackHash, watchdogHash, transcriptHash, routeIdentity, promptHash and
requestHash (null for the old prompt-only request). Read handles exclude writes
to the joined source files during the observation. Replay validates every key
and original byte identity, preserving the first observation time. No retained
observation appends a LAUNCHED row, pushes, consumes owed completion or relaunches
the stale request. Author reconciliation plus fresh admission is still needed.

New OWED_ACTIVE_WRITER terminals use landed-integration-dispatch/v2. Its common
landed/target/reason/lane/worktree fields retain v1 meaning; its executionAttribution
is either null (no retained author authority) or the closed launchId, harness,
model, effort, row, placement and routeIdentity joined to the actual execution
owner/watchdog/routing. No-owner mechanical acknowledgement does not invent a
model. v1 terminal identities still suppress duplicates and replay their existing
owed/ack contracts; both versions share one landed-target duplicate namespace.
Neither version changes completion or review authority. A missing attribution
is not evidence against an otherwise independently validated completion.

Both terminal versions pass the complete-census preflight's closed validator.
Legacy v1 Terra and current v1 Astra tuples remain distinct exact tuples; v2
permits only OWED_ACTIVE_WRITER with closed actual execution attribution or
explicit null. Duplicate, crossed and malformed terminals remain unknown.
Fresh target binding is part of planning and is repeated before publication.
Retained starts have their own plan disposition, so a later census refusal
cannot publish an earlier retained observation or consume its evidence.

The existing R3 carrier registers the named 7962 native controls. It retains
baseline8106 execution, native Git/bare-remote identities, actual launcher and
helper output, independent guard omissions, and fresh/retained reader cases.
The original battery inventory and its profile/worker limits remain intact.

## Terminal integration authority

`log-event.ps1 -IntegrationAuthoritySchema landed-integration-authority/v1`
is the sole producer of the closed, non-dispatch `rule-change` binding. Required
members are `ts`, `kind`, `integrationAuthoritySchema`, positive Int32 `pr` and
`issue`, `targetBranch`, `lineageRoot`, lowercase 40-hex `targetHead`,
`authorityState`, `authorityIssue`, `authorityCommentId`, and `operatorAuthority`.
Branch and lineage use the existing branch grammar. The timestamp is a zoned
instant; ordering uses physical append lines, never this pre-lock timestamp.
States are exactly `STOP`, `ELIGIBLE`, and `RELEASE`. STOP/RELEASE require a
positive Int32 authority issue and positive Int64 comment, with the exact
`Todd:<authorityIssue>#<authorityCommentId>` citation. ELIGIBLE permits that same
pair or three null citation fields. Optional `note` is text, never authority.
Only RELEASE has `supersedes`, a required lowercase 64-hex raw STOP row hash.
Unknown members, mixed schemas, invalid domains and duplicate JSON object keys
refuse. The host asserts the owning issue; this mechanism does not discover it.

STOP/RELEASE notes record the ruling read in that session, its UTC observation
and content. Citation is not approval: RELEASE cites a ruled Todd
`planning-repair/v1` authority, never a PASS, question or unanswered request.
There is no remote approval verifier or inference from labels, prose or owners.
Append-lock validation rejects invalid RELEASE and duplicate
`(pr,targetBranch,authorityState,targetHead,authorityCommentId)` unless a
well-formed same-target STOP/RELEASE is strictly between the prior matching row
and this append. Thus ELIGIBLE(H), STOP, ELIGIBLE(H) can be recorded but remains
stopped. These rows have no board, dispatch, attempt or cost attribution. Old
history bytes and the landed hook are unchanged.

The shared `Reduce-LandedIntegrationAuthority(history,pr,branch,head)` in
`review-head-contract.psm1` is the only reducer. It consumes complete history
bounded at 50,000 rows / 33,554,432 bytes. Malformed, duplicate-JSON-key,
unreadable or capped history, and bindings without safe PR/branch scope, are
global UNKNOWN. Missing census history is target UNKNOWN; watchdog history
must be complete. A safely scoped malformed binding or invalid RELEASE makes
only that target UNKNOWN (`CENSUS_UNKNOWN_AUTHORITY_ROW`); eligible siblings
continue. The discriminator or any authorityState/authorityIssue/authorityCommentId
field claims this closed binding; dropping its schema does not hide a bad row.
Every RELEASE must reference exactly one earlier same-target STOP;
cross-target, missing, reversed or duplicate releases are invalid. Any
unreleased STOP dominates head-independently and returns all active STOP hashes.
Otherwise the latest live ELIGIBLE must match the exact head and follow every
STOP/RELEASE. RELEASE alone
never admits, and a head change lapses eligibility, not STOP.

Census Gate A runs after reason/platform partitioning and before worktree,
holder, owed, acknowledgement, retained start, review, claim or recovery work.
STOP yields `TERMINAL_AUTHORITY_STOP`; UNKNOWN yields `AUTHORITY_UNKNOWN`.
Both are non-consuming deferrals. Gate B re-observes native branch/head and
rereads/reduces history before each RETAINED_START, HANDOFF (including recovered
completion) or LAUNCH effect. Non-ELIGIBLE or identity drift yields
`AUTHORITY_CHANGED`; global uncertainty refuses all remaining apply work.
The hidden pre-apply test seam only injects drift before these checks, never
bypasses them. Plan/v1 retains its six target keys and adds only the two Gate A
action values. Result/v1 adds `authorityRows` (raw hashes, empty when absent)
to these deferrals and AUTHORITY_CHANGED, plus `reason` for UNKNOWN/CHANGED.
A saved plan is never replay authority. Terminal LAUNCHED/OWED_ACTIVE_WRITER
schemas and request/start identities are unchanged.

For integration watchdog v3/v4 only, after live/success/unknown-owner returns
and before resume, ceiling, fallback, prompt, request, acknowledgement or
launch effects, the same reducer checks the v3 request's PR/branch or v4
retained obligation's PR/branch. STOP returns observation-result/v1
`status:TERMINAL_AUTHORITY_STOP`, `relaunch:false`, `pr`, `branch`, `stopRows`,
without writing history. Invalid bindings throw `WATCHDOG_UNKNOWN_AUTHORITY_ROW`;
incomplete history throws `WATCHDOG_UNKNOWN_HISTORY_<reason>`. Valid UNKNOWN
or ELIGIBLE preserves already-admitted recovery: v4 stoppedHead is not required
to match an ELIGIBLE row. Ordinary lanes are unchanged; STOP is not a live-lane
kill switch. Installing this default-closed census leaves unbound targets
deferred until the host supplies authority. No real binding, renewal, admission
or installation is authorized by these synthetic controls. v4 rejects
ObservationFixture; shared reducer/v3 controls are not v4 process proof.

## Interrupted canonical integration

`interrupted-canonical-integration/v1` is an explicit launcher input, not a
Force flag, prose instruction, attachment claim or completion receipt. Its
closed members are `schemaVersion`, `obligation` (unchanged owed/v1 shape),
`sources` and `state`. Sources bind the original producer request identity,
prior label/launch, exact start acknowledgement, watchdog, original prompt,
complete native transcript, canonical routing row, and nullable native-stop
checkpoint hash. State binds original branch/head, onto, stopped HEAD/commit,
old base, every native rebase metadata file, raw index, complete index stages,
all changed working-tree bytes, and full binary staged/unstaged differences.
All objects are closed and SHA fields have their exact 40/64-character type.

A historical source keeps its v1 start acknowledgement and v2 watchdog. The
adapter joins the exact original producer request and causal routing/start
identities, and parses the literal canonical helper invocation and native
conflict result. PowerShell `-File` preserves exit 2; the historical outer
`-Command` process returns exit 1. Neither mapping alone proves the body ran.
Native replay from immutable objects in owned scratch space must reproduce the
first stop, every index stage and every changed byte. Scratch Git operations
never target the product worktree. Capture or metadata presence alone refuses.
The branch and remote branch/PR refs must still equal the original head.
Current automatic integrations retain their v3 watchdog and exact canonical
`integration-dispatch-request/v1`; the embedded request must equal its retained
request file and the obligation. Retried v4 bindings inherit that same canonical
helper identity, not a helper path inferred from later resume prose.

The launcher proves the prior roots absent (reused identities also refuse),
walks possible descendants using actual complete OS observations, and checks
the full canonical ownership/worktree table. It acquires the existing fleet
admission for the closed `interrupted-canonical-integration` purpose, then
revalidates state and vacancy before plan/publication. The admission is held
through publication of the new exact child owner and released by that owner
only. Ordinary claimants also see the original branch during native rebase;
no attached HEAD is invented. No new lock or launcher exists. The exception
requires implementation/codex/gpt-6-astra/high/row7/override-Todd. Ordinary
implementation/planning dirt and detachment still refuse; detached review
keeps its existing behavior. Refusal never resolves, aborts, resets, stashes,
skips, cleans or rewrites target bytes. Force cannot reuse resume outputs.

New ownership v5, start acknowledgement v2 and watchdog v4 add exactly one
`interruptedIntegration` string containing the recursively closed binding.
Legacy records keep their original versions. A retained retry re-authenticates
the causal chain (at most three predecessors), exact current native state,
remote and prior death; it never reapplies a stale fingerprint. Only the actual
bound implementation child may invoke the existing helper's
`-ContinueInterruptedIntegration`. The helper uses a noninteractive editor,
continues the current rebase, and records any subsequent conflict as
`integration-resume-stop/v1` under that actual owner. A stop has no completion
authority, even when the outer lane exits zero.

A finished resume uses `landed-integration-rebase-complete/v2` with mode
`INTERRUPTED_OWNER_RELEASE`. It retains the binding and actual execution owner;
existing native predecessor-to-result reflog, object, clean attached result and
remote publication validators still govern completion. Ack/v3 binds the exact
completion identity and both existing consumers read it before ordinary
original-head ancestry. Historical completion/v1 and ack/v2 semantics remain.
No resume or conflict completion produces PASS, a no-conflict continuation,
provider, CI, queue or landing authority. Owed identities unrelated to this
exact integration are not acknowledged by the resume.

The registered dispatch, ownership, rebase, watchdog and R3 test carriers load
`interrupted-integration-test-support.ps1`. Their native repositories reproduce
the original 7906 and 7927 stage/path shapes with unmistakably synthetic content;
they inspect actual stage blob bodies and every staged nonconflict body, retain
raw process results and entry snapshots, and run within the canonical full
controller battery. Installation remains a separate host action after exact
independent governing review; this source contract grants no live recovery.
