# Completed rebase evidence

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
