# Chase Sets container

This local Git repository owns container configuration and reviewed orchestrator
tooling. It has no remote. The product repository is `main/`; run product Git
commands with `git -C main` or inside a product worktree. `main/` is a read-only
reference maintained by the scheduled sync.

## File ownership

- `.orchestrator/`: tracked tooling, current ledgers, current receipts, and active
  run output. `contracts/`, `controller-skills/`, and `fixtures/` are source.
- `.orchestrator/salvage/`: unfinished work requiring an explicit disposition.
- `.archive/cleanup-2026-09-12-pass2/`: compact Git and local-file recovery data
  and the cleanup's inventories, action records, and report.
- `lane-*/` and other sibling worktrees: retain active work, open PRs, and local
  changes; maintain two or three clean idle worktrees for reuse.

Generated runtime files and sibling directories are ignored regardless of
extension or name. Existing tracked scripts still show edits normally. Add new
durable runtime source deliberately with `git add -f .orchestrator/<file>`.
Contracts, controller skills, and fixtures remain discoverable by Git.

## Retention

Keep completed raw run output for seven days, extending retention for unresolved
investigations. Remove superseded snapshots, downloads, and intermediate output
once the owning work is closed and retained evidence no longer depends on them.
Keep final receipts in a compact archive. Preserve the current ledgers, live
ownership records, local configuration, and evidence supporting open work.

These are maintenance rules, not a newly installed scheduled deletion job.
New run output should be grouped by run where its producer supports that layout;
existing runtime paths must be updated with their readers before relocation.

A clean inactive checkout does not need to remain solely because its commit is
unmerged. Preserve the commit in a named ref and verified bundle, save its unique
local files, and then remove the checkout and stale local branch. Never delete a
live or dirty checkout by age alone. Do not retain entire dependency trees as
recovery archives; they can be reinstalled from the preserved source and lockfile.

## Inspect

```powershell
git status --short
git worktree list
git -C main worktree list
git for-each-ref refs/cleanup/20260912-pass2/
git -C main for-each-ref refs/cleanup/20260912-pass2/
```

## Recover work from the second cleanup

Read the inventories and action records under
`.archive/cleanup-2026-09-12-pass2/` to find the original repository, branch,
commit, and local-file ZIP. `local-recovery.zip` contains those ZIPs under
`local-files/`; extract the selected member before opening it.
`container-recovery.bundle`,
`product-recovery.bundle`, and `scratch-recovery.bundle` preserve committed
history. The repositories also retain the corresponding commits under
`refs/cleanup/20260912-pass2/<commit>` so ordinary Git garbage collection cannot
remove them when a stale local branch is deleted.

Create a new worktree from the recorded recovery ref or fetch the recorded ref
from its bundle. Overlay the saved local files from that checkout's ZIP, keeping
any existing destination files unless their replacement is intentional. Each
ZIP's `CLEANUP_RECOVERY.json` records its source and preserved symbolic links.
Archived changes from retired checkouts may include `SKILL.md.archive` files;
restore live source from Git before applying local-file recovery data.

`evidence-recovery.zip` contains `closed-receipts.zip` and the ZIPs under
`directory-receipts/`, retaining terminal evidence and historical controller
state. Extracting this package into the cleanup directory restores the paths
recorded in the action records.
Keep recovery ZIPs local: saved environment files can contain secrets. The full
checkout archives from the first cleanup are superseded by these compact copies.
