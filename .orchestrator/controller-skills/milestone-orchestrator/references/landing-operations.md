# Landing exceptions, integration and holds

Read for a landing refusal, integration obligation or actual merge hold only.
The canonical preflight/reducers own schemas and mutations.

`landing-preflight.ps1 -Action Apply` requires live review/head/check/dependency/
queue/deploy authority immediately before enqueue. An older PASS is history.
Only runtime-qualified `rebase-only-continuation/v1` may carry it forward through
a unique acyclic chain with equal ordered stable patch IDs, semantic range
equivalence, immediate authorized predecessor and no conflict resolution. New
head CI must pass. Missing PASS is `ABSENT_REVIEW_REQUIRED`, not permission:
normal new-head review follows. Conflicts get delta review of changed hunks.

After a controller refusal on otherwise complete landing authority, direct
`enqueuePullRequest` uses exact PR node ID, `expectedHeadOid`, `jump:false` once.
Reconcile unknown response against queue before retry. Record refusal and actual
result as `landing-stall`; file controller defect. If direct mutation fails,
report the bounded fallback on the live tracking issue. Intent is not enqueue.
No fallback mutates a non-authority-complete or platform-held PR.

`landed-integration-dispatch.ps1` consumes a positive landed PR/head. Complete
paginated open-PR/file census must agree on totals/cursors and resolved native
merge state. Unknown census dispatches nothing. It refreshes intersecting or
DIRTY/CONFLICTING targets, not clean disjoint ones. A live target writer receives
durable owed integration rather than a competing writer. Obligations stay until
validated exact acknowledgement; accepted-but-unacknowledged remains retryable.
Exact-result or Git-proven-descendant replay reconciles residue without another
rebase. Different branches do not wait for each other. Canonical launchers/helpers
alone produce these acknowledgements; report text is never executable authority.

`merge-hold-state.ps1` alone writes `merge-hold-state/v1`. Initialize only after
actual hold reconciliation: `-Action Initialize -ExpectedRevision 0 -Reconciled`.
Take only an authorized armed window, after canonically enqueueing PASS product
PRs: `-Action Take -ExpectedRevision <revision> -Armed -ArmedWindowId <window>
-HoldId <new-id> -Issue <issue> -Scope queue|prs [-Prs <PRs>]
-ExpiresAt <UTC-within-two-hours>`. Lift actual hold with `-Action Lift
-ExpectedRevision <revision> -HoldId <id>`; disarm with `-Action Disarm
-ExpectedRevision <revision> -ArmedWindowId <window>`. Re-arm gets new identity.
Expiry is observation, not automatic lift; unknown state is not no-hold.
State records describe authorized actions, never grant authority themselves.

Staging-red holds deployable landings except its repair candidates (brief names
incident); runtime-proven non-deployable heads may land. Judge Change Scope,
not title. Never bypass actual safety or missing evidence as controller noise.
