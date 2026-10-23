# Controller Battery CI

The public repository is https://github.com/chase-sets/chase-sets-controller.
`.github/workflows/controller-battery.yml` accepts manual dispatch and pushes to
`main` only. There are no PR triggers. Actions are SHA-pinned, tokens are
read-only, checkout credentials are not persisted, and no repository secrets
are required. A calibrated plan uses the smallest feasible shard count in
16, 17, 18 with LPT maximum at most 250000 ms. Each execution shard must finish
within 300000 ms. Legacy plans without `shardCount` still use exactly ten
receipts. Tests within
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
This development clone has public history. Publish its normal author branch
without rebasing pushed commits, amending or force pushing. Never fetch the
private container history into this clone. Select the candidate branch as the
workflow ref: `controller_head` selects tested sources, not runner scripts.

```powershell
git push origin HEAD
gh workflow run controller-battery.yml -R chase-sets/chase-sets-controller --ref <candidate-branch> -f controller_head=<source-sha> -f product_sha=<immutable-product-sha> -f scope=full
```

The same candidate runner/workflow commit and product SHA must execute baseline
and candidate sequentially for a gate pair. Keep every run ID, exact plan bytes,
raw item logs, shard receipts and final receipt. A green shard job is not proof
that its items passed.

## Calibration

`controller-ci-parts.json` owns the four oversized suites. Default and legacy
suite entrypoints remain available. Routing parts are derived from all current
case and mutant tables; mutant children retain their original focused cases.
Board arms keep candidate/inert and ten-item/scan together. Cleanup remains a
whole item, including construction and synchronous teardown.

Calibrate the entire candidate inventory on hosted runners before the gate.
`controller-ci-record-durations.ps1 -RecordPlanPath <plan> -ResultPath <final>
-OutputPath .orchestrator/controller-ci-durations.json` records exact Git blob
UTF-8 source digests, not console-decoded text or worktree fallback. CRLF is
normalized to LF without changing the final newline. Each record binds the
run, source, runner, product, exact plan digest and conservative tracked-source
dependency closure. The profile itself is excluded from that closure.

Run `controller-ci-prediction.ps1 -EvidenceDirectory <evidence> -CalibrationPlanPath
<plan> -WriteProfile` to replay all three bounded choices and record the smallest
feasible N. No feasible count means stop for decomposition. Calibration may use
fallback; the gate must have only `recorded`, `recorded-part` and `local-only`
timing sources. Records older than 30 days or changed dependencies cannot be
used as fresh proof. No timeout, retry, skip, sampling or waiver is introduced.

The hosted inventory explicitly adds `check:controller-ci-coverage`,
`check:controller-ci-sharding` and `check:controller-ci-record-durations` to the
source battery's identities. Each is required and measured, not a replacement.

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
