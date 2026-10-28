# Platform supervision

This thread owns the orchestration platform's loops, their runs and executor,
and the controller side of `orchestrator-shared` Platform handoff. The product
loop hands Chase Sets issues to the platform loop and takes them back only
through that contract; it never observes, starts, stops or repairs a platform
run.

## Handoff file

This thread alone writes the product container's
`.orchestrator/platform-handoff.json`. Set `accepting: true` only while a
Chase Sets supervisor started with a `handoff` object naming both labels is
live. Write `accepting: false` before stopping that supervisor, and as soon as
it is found stopped. Raise `maxInFlight` from the weekly platform scorecard
(`platform-scorecard.ps1`) and that week's `platform-take-back` markers. The
tunable numbers live only in that file, never in skill text.

This thread also owns the git-ignored, machine-local
`.orchestrator/lane-priority.json`: `{"schemaVersion":"lane-priority/v1",
"priorityClass":"BelowNormal"}`. Allowed classes are `Normal`, `BelowNormal`,
and `Idle`; absent defaults to `BelowNormal`, invalid/unreadable falls back to
`Normal`. `dispatch-lane.ps1 -PriorityClass Normal` overrides one launch.
Applied class/source persist in its watchdog spec. Host processes stay Normal;
only the launched agent/supervisor tree inherits. See `contracts/lane-priority.md`.

## Runs

Start or resume a platform run only from Windows through the platform
checkout's `scripts/executor/start-loop.ps1 <config>`, recording the config
path, run name, executor SHA and supervisor PID. Start or resume a Chase Sets
run only with a `handoff` object naming `dispatch:platform` and
`dispatch:platform-return`. Every run started that way keeps `loop.json`,
`start-record-r<N>.json`, `start-loop-r<N>.out` and `supervisor.log` under the
container's `.orchestrator\platform-runs\<run>\`. Honor an active setup owner
until it reports that identity and releases responsibility.

Observe runs and their PRs read-only. Use the platform's native status output
when it is current and complete; otherwise take the newest run by start
record, tail its `supervisor.log`, and check the exact `supervise.mjs` process
identity (PID, parent and process group, start instant, command and config)
against the run's start record. A historical log line or a matching PID alone
is not liveness, and alert silence is not health. Unresolved evidence stays
unknown. Routine observation posts nothing.

Never hand-edit the platform checkout or the WSL executor checkout; platform
defects go to the platform's self loop, which owns every platform-repository
issue. This thread chooses the next platform fix, labels a platform issue
`ready` only after an independent readiness review, and decides each unpark
and resume, recording the decision on the platform issue. Upgrade the
executor only while no Chase Sets supervisor is live.

## Returns

Each cycle, read the Chase Sets issues carrying `dispatch:platform-return`
from a complete paginated read. While no Chase Sets supervisor is live, this
thread is their holder: acknowledge each one (`by: controller`) only after
confirming that no process of the run remains, the supervisor and every
descendant, and after the shared acknowledgment's merge-queue check; then make
the remaining acknowledgment writes in order. When a live holder has not
acknowledged a return within `releaseHours`, write `accepting: false`, stop
the run, and acknowledge the same way.

## Platform fixes

For each distinct platform cause named in `platform-take-back` comments, file
one platform issue through the platform repository's planning path. Do the
same for the platform cause of a platform PR that turned Chase Sets `main` or
the deploy red; the product loop's breaker repairs `main` itself.
A stop cap or chain stop is not a wait for Todd: this loop picks the fix
(a narrow repair, a rerun, or reordering the chain), applies it, records the
decision on the tracking issues, and continues.

Criteria for retiring the host loop live in the platform roadmap.
