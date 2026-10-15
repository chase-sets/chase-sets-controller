# chase-sets container

This directory is NOT the chase-sets repository. It is the container that holds the repo and all of its worktrees, so selecting this one directory grants an agent access to everything.

## Layout

- `main/` — canonical checkout of chase-sets and a **read-only reference**. Never edit, commit, or install dependencies here. It is synced to `origin/main` by `./UPDATE_MAIN_FROM_ORIGIN.ps1` (a scheduled task runs `.orchestrator/run-main-sync.vbs`, which launches `.orchestrator/run-main-sync.ps1` without a console window); local changes in `main/` are discarded unconditionally, and every sync sweeps all ignored/untracked clutter (stray `node_modules`, logs, artifacts, orphaned workspace dirs). Only `.env.*.local` files survive.
- `lane-01/` … `lane-NN/` — persistent delivery-lane worktrees.
- `YYYYMMDD-<topic>/` — ad-hoc worktrees. Spawn siblings with `git -C main worktree add ../<name> <ref>` or `node main/scripts/worktree-add.mjs`.
- `.orchestrator/` — delivery-loop state. Scripts and reviewed controller-skill releases under `.orchestrator/controller-skills/` are tracked; logs, lease, and salvage are machine-local. Install controller-skill releases with `.orchestrator/install-controller-skills.ps1` only at an independently reviewed exact commit.
- `.agents/`, `.codex/` — directory junctions into `main/`, so Codex launched at the container root sees the repo's skills and config. Recreate with `./bootstrap-container.ps1` if missing. Never copy files into them; edit the repo instead.
- `.claude/` — real directory reserved for container-level Claude Code settings (currently holds only machine-local state; no settings file exists yet). Repo skills are auto-discovered from `main/.claude/skills` (they appear scoped as `main:<skill>`).

## Git identity

This container is itself a small meta-repo that tracks container config (this file, the sync/bootstrap scripts, orchestrator scripts). Any git or gh operation concerning chase-sets itself must run with `-C main` or inside a lane worktree — never against the container repo.

## Background process windows

Todd requested that background orchestration jobs never open console windows.
Hide the outer launcher, not just its PowerShell or worker child, and preserve
stdout/stderr logging and the existing canonical dispatch/verification paths.
For `Start-Process`, always supply `-WindowStyle Hidden`. For WMI/CIM launches,
create a `Win32_ProcessStartup` instance with `ShowWindow = [uint16]0` and pass
it as `ProcessStartupInformation` to `Win32_Process.Create`; omitting that
argument opens visible `cmd.exe`/PowerShell windows even with redirected output.
Do not terminate or restart active workers just to hide their windows.

## Dependencies

Every checkout on this drive shares pnpm's per-drive content-addressed store (`D:\.pnpm-store`) automatically; `pnpm run deps:install` inside a worktree is cheap after the first install. Set `CHASE_SETS_PNPM_STORE_DIR` only if the store must live elsewhere.

Repo-wide engineering instructions live in `main/AGENTS.md`.
