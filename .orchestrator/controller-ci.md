# Controller Battery CI

The public repository is https://github.com/chase-sets/chase-sets-controller.
`.github/workflows/controller-battery.yml` accepts manual dispatch and pushes to
`main` only. There are no PR triggers. Actions are SHA-pinned, tokens are
read-only, checkout credentials are not persisted, and no repository secrets
are required. Each run has ten independent Windows-hosted shards. Tests within
a shard run serially with PowerShell 7.6.5, Node 24.15.0 and pnpm 11.21.0.

## Trigger and collect

Run these in the controller author worktree, not the product checkout:

```powershell
gh workflow run controller-battery.yml -R chase-sets/chase-sets-controller --ref main -f controller_head=controller-8478-f2 -f product_sha=0f3e27ce77289a8dbc5c96d3889946a101dc3cea -f scope=full
gh run list -R chase-sets/chase-sets-controller --workflow controller-battery.yml --limit 5 --json databaseId,headSha,status,conclusion,url
gh run view <run-id> -R chase-sets/chase-sets-controller --json status,conclusion,jobs
gh run download <run-id> -R chase-sets/chase-sets-controller -n controller-battery-result -D <empty-result-directory>
gh run download <run-id> -R chase-sets/chase-sets-controller -n controller-plan -D <empty-plan-directory>
```

Use short bounded polls, never `--watch`. Optional `-f items=...` accepts exact
comma/newline-separated battery identities. Omitted items means the selected
head's entire required inventory. A subset is explicitly incomplete, never a
release PASS. `impact` without an installed, published baseline safely expands
to full, as it does in the local battery. CI does not read installed skills or
claim a private installed baseline.

The plan invokes the selected head's unchanged `-ValidatePlanOnly` mode and
captures its exact argument arrays. The pinned PowerShell distribution is
provisioned at the legacy committed canonical path inside each disposable VM;
this does not change the local host or weaken host-pin assertions. The
controller checkout is `container/controller`, and the public product is
`container/main` at the resolved immutable input SHA. No dependencies are
installed in the product checkout, and no host runtime directories are copied.

## Publication

Local container history must not be pushed: the publication scan found
sensitive historical runtime-token captures. Scan every candidate tracked tree
before publishing it. Do not add a push remote to the shared container, push
`--all`, mirror, or use the source implementation branch in a push refspec.
Create a parentless snapshot from the exact source tree with its mapping trailer:

```powershell
$source = git rev-parse HEAD
$tree = git rev-parse "$source`^{tree}"
$snapshot = "Controller snapshot`n`nSource-Controller-Head: $source" | git -c user.name=chase-sets-controller -c user.email=controller@users.noreply.github.com commit-tree $tree
git push https://github.com/chase-sets/chase-sets-controller.git "${snapshot}:refs/heads/snapshot/$source"
gh workflow run controller-battery.yml -R chase-sets/chase-sets-controller --ref main -f controller_head="snapshot/$source" -f product_sha=<immutable-product-sha> -f scope=full
```

Each new source head gets a new snapshot ref, so no force push or local history
rewrite is necessary. Keep the trusted workflow on the public `main` lineage;
workflow updates must include only scanned changes on that already-safe public
lineage, never a parent from private container history. Initial workflow
activation is a normal fast-forward commit atop the public F2 orphan snapshot.

## Results and limitations

The result artifact contains `final.json` using `controller-battery-result/v1`,
`controller-ci.log` with per-item RESULT lines, and each shard's raw logs and
receipt. `controllerHead` maps back through the snapshot's
`Source-Controller-Head` trailer; `ci.checkoutHead` separately records the
actual executed public SHA. Product SHA, workflow SHA, run ID, per-shard timing,
exclusions and non-hermetic inventory are explicit. Missing/duplicate/extra
results, changed plan digests and inconsistent PASS/exit codes fail closed.

The legacy `rawLog.relativePath` is `.orchestrator/artifacts/controller-ci.log`;
place the downloaded raw log there relative to the receipt consumer's root
when validating its length and SHA256. A download alone is not a governing or
installation receipt. No existing host admission or installation guard is
changed by this author lane.

Host-only items return `exitCode: 125`, `result: LOCAL_ONLY`; they are never
converted to PASS. Native carrier tests that observe a parent host fleet are
also listed in `ci.notHermetic`. Exact historical discriminator fixtures
excluded from the public snapshot remain local-only. Model CLI/sandbox tests
remain local-only; this workflow never installs or launches a model CLI.
The classification lives in `Get-CiRestriction` and must be revisited when the
candidate removes those dependencies. No test assertions, timeouts, product
files or local verifier locks are altered.

The runner provisions both pnpm 11.21.0 distributions: a SHA512-checked native
package with the host's exact direct-binary CMD layout and a separate native
copy for alternate-path controls, plus a Node-hosted global-prefix install for
the verifier's existing safe resolver. A plain writable private TEMP/TMP carrier
is shared by each shard's fixtures and children. No resolver or test is patched.
Three legacy receipt fixtures inherit the selected candidate's existing
synthetic routing-registry helper; no live account registry is copied.

Additional snapshot restrictions are explicit: admission-temp-cleanup,
review-head-reducer, issue-6997-autonomy-policy and heavy-slot require unpublished
historical commits. They remain local-only rather than substituting historical
bytes or rewriting Git identities. Host-heavy-verifier requires installed WSL
native resources. Planning-review-routes requires untracked installed ledgers.
Landing-preflight and the issue-6254 suite read pinned live-host evidence and
are both LOCAL_ONLY and NOT_HERMETIC. These exclusions do not discharge local
proof requirements. The issue-6254 discriminator is independently hermetic.

A run with failures is FAIL. A run with only passing CI items plus exclusions
or an explicit subset is INCOMPLETE_CI and exits nonzero. It is not an
installable PASS and does not claim whole-battery parity. Compare eligible
per-item PASS/FAIL with the source local result and report every mismatch;
do not infer load sensitivity merely from a different hosted outcome.

Local development checks for this adapter are the parser, actionlint, and the
small deterministic `controller-ci.test.ps1` merge/selection test. Full local
gates still require the canonical heavy verifier; CI execution entrypoints
refuse local machines. This workflow is not permission to run a local battery
outside its exclusive verifier admission.
