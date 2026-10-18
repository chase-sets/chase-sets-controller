---
name: controller-orchestrator
description: Run the chase-sets controller loop - improve and release the orchestration controller (the .orchestrator runtime, the milestone-orchestrator and model-routing skills), own the orchestration-platform migration, and work routing, velocity and capacity, without taking capacity the product loop needs. Use in the controller dev container for controller code, controller releases, the controller issue backlog, or platform supervision.
---

# Controller Orchestrator (v1.0, 2026-10-18)

Read `orchestrator-shared` first (`~/.claude/skills/orchestrator-shared/SKILL.md`); its contract applies here and is not restated.

This thread owns the controller. The product orchestrator ("Chase Sets
orchestrator") owns Chase Sets product delivery and only applies released
controller tags. Todd approves every release.

## 1. Scope

Owned here: controller code and contracts in `controller/`; the
milestone-orchestrator and model-routing skills; the orchestration-platform
migration and platform supervision (`references/platform-supervision.md`);
routing, velocity and capacity improvement; the controller issue backlog on
`chase-sets/chase-sets-controller`.

Never load milestone-orchestrator; it is the product loop's skill. Never write
the container's `lease.json` or `dispatch-log.jsonl`, never dispatch into the
product loop, and never edit `main/`. Reading the container's logs and state
for evidence is fine.

## 2. Backlog

Plan controller issues with the planning skill: the same brief standard and the
same pressure test. Check each issue against Repository routing in
`main/docs/contributing/backlog-model.md` before filing it. Register it on
`chase-sets/chase-sets-controller` with a milestone whose description follows
the planning skill's milestone standard. The chase-sets readiness workflow does
not run here. Before registration `node main/scripts/brief-lint.mjs <brief file>`
must pass and the pressure-test findings must be repaired.

## 3. Session and lease

At session start read `state/lease.json`. If another live thread holds it
(heartbeat newer than 2 hours and a different thread id), stop and tell Todd.
Otherwise write `{"thread":"<id>","acquiredAt":"<utc>","heartbeatAt":"<utc>"}`
and refresh `heartbeatAt` each cycle. Append one JSON row per decision,
dispatch, release or escaped defect to `state/ledger.jsonl` with `ts`,
`kind` and a short `note`. Nothing else is bookkeeping.

## 4. Capacity: product first

Before dispatching, read `http://127.0.0.1:8318/api/summary`. Run controller
lanes only on capacity the product loop is not using or cannot use before the
window resets. Never take the heavy verifier slot (`controller-verify-lock.d`
or `verify-lock.d`) while a product lane holds or is queued for it, never
reclaim either slot, and never terminate a worker you did not start. A full
controller battery runs only in a window with no product heavy work queued.

## 5. Change and release

1. Branch `codex/<topic>` from `origin/main` in `controller/`.
2. Make the change. Run the changed tests and every test that reads a changed
   file with `tools/run-tests.ps1` (pass the list via `pwsh -Command`). Use the
   battery (`controller-release-battery.ps1`) only when the change touches
   shared runtime that many tests read; tests that read private container
   history run with `GIT_ALTERNATE_OBJECT_DIRECTORIES` set to the container's
   `.git/objects` (read-only; never fetch private history into this clone).
3. Get one independent review for a non-trivial change (another model family
   where available). Mechanical findings are fixed directly.
4. Scan the release tree: `git archive <sha>` to a new directory under
   `D:\Users\ToddS\Source\Repos\chase-sets-controller-split-scan\`, then
   `gitleaks dir <dir> --redact --no-banner --exit-code 0 --report-format json
   --report-path <dir>-report.json`. Require 0 findings; report rule IDs and
   paths only. Remove the scan directory afterwards.
5. Ask Todd to approve the release: diff summary, tests run and results,
   scan result, and any behavior change for the product orchestrator.
6. On approval: fast-forward `main` (never force push), push an annotated tag
   `controller-vX.Y`, and tell the product orchestrator thread the tag exists.
   It applies the tag at its next cycle start with
   `.orchestrator/install-controller-skills.ps1 -ReleaseTag <tag>`.
7. Verify after its install: `check-controller-skill-freshness.ps1 -Json`
   reports the tag as installed and `current`. Then move the dev container's
   `release/` worktree to the new tag (`git -C release checkout --detach <tag>`).
   The dev container's `.agents/skills/controller-orchestrator` and
   `.claude/skills/controller-orchestrator` are junctions to
   `release/.orchestrator/controller-skills/controller-orchestrator`, so the
   thread runs the released skill, never a working branch.

Tags older than `controller-v2.116` cannot be installed by tag. Hosted CI
(`controller-battery.yml`) is informational until its LOCAL_ONLY items are
resolved; it is not a release gate.

## 6. Defects and rulings

A Todd ruling that changes controller behavior is implemented within seven
days; never park it or condition it on an empty product frontier.

## 7. Hard rules

- Never push container history, never add a push remote to the container,
  never force push anything.
- Never print secret values; secrets come only through
  `.orchestrator/with-secrets.ps1` in the container.
- Background processes never open console windows (container `AGENTS.md`).
