# Controller Battery CI

The public repository is https://github.com/chase-sets/chase-sets-controller.
`.github/workflows/controller-battery.yml` accepts manual dispatch and pushes to
`main` only. There are no PR triggers. Actions are SHA-pinned, tokens are
read-only, checkout credentials are not persisted, and no repository secrets
are required. A calibrated plan raises the shard count from 16 until the LPT
predicted maximum is at most 200000 ms, capped at 32. When no count meets that
target, the cap is used if its predicted maximum is at most 300000 ms. Each
execution shard must finish within 300000 ms. The workflow input `role`
(`candidate`, the default, or `baseline`) is passed to Plan mode and decides
enforcement; the runner ref and checkout are not consulted
([#123 Run dispatch-lane.test.ps1 on hosted CI in parts within the shard bound](https://github.com/chase-sets/chase-sets-controller/issues/123)).
Unless the role is `baseline`, Plan refuses a plan whose largest shard
`estimatedMs` exceeds 300000 or whose items use `fallback`, whole-item
`stale-recorded` or `*-split-estimate` timings; `stale-recorded-part` is
accepted. This holds for a candidate dispatched from `--ref main` against a
foreign checkout. A `baseline` run is a comparison run. `planning.bound`
records `role`, `enforced`, `boundMs`, `maxEstimatedMs`, `checkoutHead`
and `runnerHead` for both roles.
Legacy plans without `shardCount` still use exactly ten receipts. Tests within
a shard run serially with PowerShell 7.6.5, Node 24.15.0 and pnpm 11.21.0.

## Trigger and collect

Run these in the controller author worktree, not the product checkout:

```powershell
gh workflow run controller-battery.yml -R chase-sets/chase-sets-controller --ref main -f controller_head=controller-8478-f2 -f product_sha=0f3e27ce77289a8dbc5c96d3889946a101dc3cea -f scope=full -f role=candidate
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
gh workflow run controller-battery.yml -R chase-sets/chase-sets-controller --ref <candidate-branch> -f controller_head=<baseline-tag-or-sha> -f product_sha=<immutable-product-sha> -f scope=full -f role=baseline
gh workflow run controller-battery.yml -R chase-sets/chase-sets-controller --ref <candidate-branch> -f controller_head=<source-sha> -f product_sha=<immutable-product-sha> -f scope=full -f role=candidate
```

The same candidate runner/workflow commit and product SHA must execute baseline
and candidate sequentially for a gate pair. The baseline passes
`-f role=baseline`, so its plan records `enforced: false` and the base's
shard sizes cannot fail its plan. The candidate passes `-f role=candidate`
(also the default) and must satisfy the bound. Keep every run ID, exact plan bytes,
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
run, source, runner, product, exact plan digest and conservative per-item
dependency closure. Runtime and fixture inputs, referenced proof siblings and
the actual runner/workflow bytes are retained. Unrelated proof entrypoints
and planning/recording inputs do not invalidate an ordinary suite; CI-library
checks retain the full closure. The profile itself is excluded.
Use `-Append` for additional reconciled hosted runs. Planning takes the maximum
of all source/dependency-matching records within 30 days, never the latest or
minimum sample. Baseline, re-probe, calibration and gate records retain their
original run/head/plan provenance; they are not relabeled as new executions.

Run `controller-ci-prediction.ps1 -EvidenceDirectory <evidence> -CalibrationPlanPath
<plan> -WriteProfile` to replay N=16..32 and record the chosen N (above). No
count within 300000 ms means stop for decomposition. Every estimate must be a
hosted observation of that exact execution identity: `recorded`,
`recorded-part`, `stale-recorded-part` or `local-only`. A whole item must
be recorded at its current source and dependency set; whole-item
`stale-recorded`, fallback and equal-weight `*-split-estimate` timings
refuse, in prediction and in an enforced Plan. A split part with only stale records uses its own slowest stale
observation; an equal-weight share of the whole suite is used only for a part
that was never observed. Record a full hosted run of the head under test
(`-Append`) so its records carry the current source digests, and record both
gate runs so the next plan takes the slowest hosted observation per item. Records older than 30 days or changed dependencies cannot be
used as fresh proof. No timeout, retry, skip, sampling or waiver is introduced.

After any change to the runner or workflow (`controller-ci.ps1` or
`.github/workflows/controller-battery.yml`), every whole item's records are
`stale-recorded`, because those bytes are in every item's dependency closure,
and an enforced candidate plan refuses them. The first hosted run after such a
change is therefore a recording run:

1. Push the change and dispatch a full run at its head with `-f role=baseline`
   (no items). Its plan records the bound without enforcing it.
2. Append that run's durations with `controller-ci-record-durations.ps1
   -RecordPlanPath <plan> -ResultPath <final> -OutputPath
   .orchestrator/controller-ci-durations.json -Append`. The recorder rewrites
   the profile without `shardCount`, so then run `controller-ci-prediction.ps1
   -EvidenceDirectory <evidence> -CalibrationPlanPath <recording plan>
   -WriteProfile` to restore it; without it Plan falls back to 18 shards.
   Commit only the profile. The profile is excluded from every digest, so this
   commit leaves the new records current.
3. Only then dispatch `role=candidate` runs, at the durations commit.

The `controller-ci*` checks digest every tracked file except the profile, so
any other commit after the recording run, documentation included, makes them
`stale-recorded` again and needs a new recording run.

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
candidate removes those dependencies.

Some controls inside hosted-PASS items still need private history and skip on
hosted runners. In `dispatch-lane.test.ps1` (launcher setup shared by parts
`refusal-foundation` and `refusal-harness`, and the whole run), the
`installed-baseline` control from
[chase-sets#9382 \[controller\] A never-launched strict controller-review prelog strands its exact head: void it from launcher evidence and make the prepared v1 prelog exact](https://github.com/chase-sets/chase-sets/issues/9382)
reads launcher baseline
`24a00072a5d10b93c290d805d900920e3a2aa84a` through
`GIT_ALTERNATE_OBJECT_DIRECTORIES`. Hosted runners leave that unset, so the
control does not run and its log prints
`SKIPPED #9382 installed-baseline control: ...` after the
`LOCAL_PRIVATE_HISTORY` line. The same-input `AC1-AC4-void-omitted` mutant
still runs. A hosted PASS for those parts therefore does not include the
installed-baseline control; it runs only in a local battery with the
alternates configured. No test assertions, timeouts, product
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
