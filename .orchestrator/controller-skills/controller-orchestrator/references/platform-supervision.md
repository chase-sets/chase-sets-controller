# Platform supervision (moved from milestone-orchestrator v2.115)

Moved verbatim from the product skill on 2026-10-18. The controller thread now
owns these duties; the product orchestrator only reads the ownership register
(section 1 of the container's `.orchestrator/platform-handoff.md`). Read
"before step 7" and "incumbent" in their original product-loop sense: they
describe what must hold for product delivery, which this thread now observes.

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
unavailable, stale or incomplete, observe the current run of each loop read-only.
Every run started through `start-loop.ps1` keeps `loop.json`, `start-record-r<N>.json`,
`start-loop-r<N>.out` and `supervisor.log` under the container's
`.orchestrator\platform-runs\<run>\`; take the newest run by start record and tail its
`supervisor.log`. Run state lives in WSL under `/root/orchestration-m1/runtime/<run>/`.
The root-level `/root/orchestration-m1/supervisor.log` and
`/root/orchestration-m2/supervisor.log` are legacy (last written 2026-09-22 and
2026-09-13) and are never current evidence. Check the exact
`supervise.mjs` process identity read-only: PID, parent/process group, start
instant, and command/config against the run's start record. A historical log
line or matching PID alone is not liveness. Unresolved evidence stays unknown;
unrelated incumbent work continues. ISS-138 alert silence is not health
evidence and does not replace current-state or pre-mutation checks.
A stop cap or chain stop is not a wait for Todd: this loop picks the fix
(a narrow repair, a rerun, or reordering the chain), applies it, records the
decision on the tracking issues, and continues.
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
