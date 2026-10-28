# Lane admission after commit or rebase (#8107)

## Authority

The container `heavy-slot.cjs` is authoritative for identity provenance. The
preload explicitly opts into `launcherConfiguration(..., { useForAcquisition:
true })`, registering the validated `CHASE_SETS_HEAVY_ADMISSION_CONFIG` for
that process, including unclassified entry scripts. Subsequent calls through
the unchanged product `scripts/lib/heavy-slot.mjs` adapter use that same claim.
An absent claim selects live-Git derivation. Standalone direct callers without
an active preload retain live-Git derivation even with stale or malformed
environment claims; merely parsing a claim does not opt in. Explicit caller
configuration retains precedence. Neither path rewrites `head`.
The claim's worktree must equal the caller's canonical Git worktree root.

For attached branch admission, the launch head is a branch-history anchor,
not the execution head. The branch must still match exactly. A moved head is
admitted only if its branch-local reflog connects the live tip back to the
anchor through ancestry-preserving transitions or completed rebases with a
common ancestor. An unrelated commit, missing anchor, recreated branch log,
or non-ancestral reset cannot supply that proof. Missing/expired reflog proof
fails closed; callers must not repair it by rewriting the launch claim.

The acquired owner always records live Git HEAD. Exact branch/HEAD revalidation
at attachment and all existing nested continuation checks remain unchanged.
Explicit immutable-head review and direct host gates retain exact-SHA binding.
This does not fix or bypass #7956's nested-continuation refusal.

## Declared diagnostics

The `-Diagnostic` route is a host-declared, case-sensitive standalone Node
entry. Its repository-relative path and SHA-256 remain pinned by
`diagnostic-declarations.json`; the declaration kind must be
`standalone-node`, and `-DiagnosticBudgetSeconds` is required and must be in
the closed interval `(0, 86400]` (and no greater than the declaration's
maximum). An optional `dependencies` array declares an exact-byte closure of
at most 64 repository-relative `.mjs`, `.js` or `.json` files, each with a
SHA-256. Paths must be normalized, inside the worktree, free of reparse points,
unique (case-insensitively), and different from the entry. Every declared file
must exist and match its hash before launch. The receipt retains these paths
and hashes. The preload admits only their exact realpaths and checks loaded
bytes against their hashes before evaluation, refusing a post-check swap.
Omitting the array preserves the existing policy; ignored siblings receive
no implicit authority. Diagnostic module imports otherwise are admitted only
when the resolved file is tracked at the bound clean Git head, is under the worktree root
`node_modules`, or is under a nested package's `node_modules` only when that
package's `package.json` is tracked at the bound head. The preload refuses
other files before evaluation. It hashes the bytes returned by Node's
`nextLoad` hook (falling back to file bytes only for CommonJS, whose hook
source is null) and records each loaded file's path and SHA-256 in a
per-process manifest. The verifier merges the manifests without allowing a
child to overwrite its parent's records and requires the declared entry to
be present.

After admission succeeds, the diagnostic launcher unconditionally sets
`CHASE_SETS_HEAVY_ADMITTED=1` in the child environment, overwriting any caller
value. It does not set this flag for non-diagnostic gates. Refused admissions
never launch the diagnostic payload. Other caller inputs, including `CHROME`
and `OPENSSL`, are inherited unchanged; the existing admission-specific Node
options, configuration, script-shell and slot-transport handling still applies.

The diagnostic receipt schema is `host-heavy-diagnostic/v1`. A completed
diagnostic reports its native exit code in `nativeExit`; a result file written
beside the entry during the run is hashed as `resultSha256`, while a
pre-existing result file is a refusal. A wall-clock timeout reports exit `124`
while preserving the native termination code. Windows Job Object peak memory,
total user/kernel time, and total process count are sampled before the Job
Object is closed. Unsafe or pre-existing receipt paths are refusal failures
and never produce a success result.

In diagnostic mode, `new Worker`, `process.execve`, and
`process.binding('spawn_sync' | 'process_wrap')` are refused. Node child-process
launches are refused unless the child environment carries exactly the host-set,
preload-only `NODE_OPTIONS` string and the exact
`CHASE_SETS_HEAVY_ADMISSION_CONFIG` value. The check runs twice. `spawn`, `exec`,
`fork`, `execFile`, and their synchronous variants read options only from the
slot Node reads, and refuse environment keys that contain `=` or name a guarded
variable in another case. Every route, including `new ChildProcess().spawn` and a
reused child handle, then reaches the native `spawn_sync` or `process_wrap` spawn.
There the environment block is copied once, each guarded variable must appear
exactly once with its exact name and value, and Node receives that copy. Native
addons (`process.dlopen`) and already-running external processes remain outside
the diagnostic boundary. The check reads only the environment of the direct child:
a permitted shell or non-Node child that clears `NODE_OPTIONS` before starting
Node is not seen.
Manifests from different processes that disagree on a module's digest refuse
the run.
The Job Object still supplies descendant cleanup on Windows.

## Local E2E

E2E is not hosted-only. The closed local invocation is:

Bind `$CanonicalContainerRoot` to the absolute root of the installed supervising
container, not the candidate worktree; invoke that container's installed verifier.

```powershell
$CanonicalContainerRoot = '<installed-supervising-container-root>'
pwsh -NoProfile -File (Join-Path $CanonicalContainerRoot '.orchestrator/invoke-heavy-verifier.ps1') `
  -Gate test:e2e:suite `
  -E2eSuite marketplace_account `
  -Worktree '<lane-worktree>' `
  -Lane '<lane>' `
  -Branch '<live-branch>' `
  -ClaimedHead '<live-head>'
```

`E2eSuite` is one identifier, passed as a separate argument to
`pnpm run test:e2e:suite -- <identifier>`; the product suite registry still
validates the identifier. Other gates reject this parameter. The new gate's
nested kind closure is the existing Playwright closure. No existing gate or
WorkspaceTest allowlist changes.

## Focused controls

Run from the container worktree, with no dependency installation:

```powershell
pwsh -NoProfile -File .orchestrator/heavy-admission-preload.test.ps1 -LaneEvolutionOnly
pwsh -NoProfile -File .orchestrator/heavy-admission-preload.test.ps1 -LaneEvolutionOnly -GuardRevision 530540eb7a4ae5c1115063567aba1d7c3b69e78f
pwsh -NoProfile -File .orchestrator/heavy-admission-preload.test.ps1 -LaneEvolutionOnly -AcceptAnyHeadMutant
pwsh -NoProfile -File .orchestrator/heavy-admission-preload.test.ps1 -E2eGateOnly
pwsh -NoProfile -File .orchestrator/invoke-heavy-verifier.test.ps1 -LegacyOnly
pwsh -NoProfile -File .orchestrator/heavy-slot.test.ps1 -IdentityOnly
pwsh -NoProfile -File .orchestrator/heavy-slot.test.ps1 -CurrentBindingOnly
pwsh -NoProfile -File .orchestrator/heavy-slot.test.ps1 -LauncherNonReentryOnly
```

The baseline and mutant commands must exit 1: the baseline gate exits 73
after an ordinary commit; the mutant executes the unrelated-head body with
exit 0 instead of refusing with 73. The candidate commands must exit 0.
The default preload suite also runs the new evolution and E2E controls.
All fixtures use disposable repositories, inert bodies, and private locks.
The product adapter is copied read-only into the fixture, not edited.

No release qualification, installation, full controller battery, real browser
suite, live-owner mutation, timeout increase, or test omission is authorized
by these controls.

## Observed discriminator output (2026-09-22)

Baseline guard at `530540eb7a4ae5c1115063567aba1d7c3b69e78f`, harness exit 1:

```text
REPRO pinned-H0 ordinary-commit H0=ab84a158c99fe65efbb2e0cf9e01c71c5499e27c H1=37d43d3c8251c54b8ad2b00a65daf60dae6c7901 gateExit=73 body=False
ASSERTION FAILED: same-branch commit retains admission exit code is 0 (actual 73)
```

Candidate, harness exit 0:

```text
REPRO pinned-H0 ordinary-commit H0=98811d40a9be499c4b98b2ded994956b23a279d8 H1=865177832af09720dcd162de19020d2d8eb64e19 gateExit=0 body=True
PASS preload rebased gateExit=0 body=True ownerReleased=True
PASS preload foreign-head gateExit=73 body=False ownerReleased=True
PASS preload foreign-branch gateExit=73 body=False ownerReleased=True
PASS preload foreign-record gateExit=73 body=False ownerReleased=True
PASS product-adapter rebased gateExit=0 body=True ownerReleased=True
PASS product-adapter foreign-head gateExit=73 body=False ownerReleased=True
PASS product-adapter foreign-branch gateExit=73 body=False ownerReleased=True
PASS product-adapter foreign-record gateExit=73 body=False ownerReleased=True
```

Accept-any-head mutant, harness exit 1:

```text
PASS preload rebased gateExit=0 body=True ownerReleased=True
ASSERTION FAILED: preload foreign-head exit code is 73 (actual 0; stderr=; stdout=)
```

The baseline refusal retains the literal existing diagnostic, including its
existing repeated suffix; the candidate tests assert complete refusal text,
not just a substring. No launch claim is re-encoded with a replacement head.
## Long Product Gate Admission (#230)

CONTRACT_VERSION: heavy-lane-admission/v1

The `-LongProductGate` dispatch route is a closed implementation-lane route
for one gate: `test:scripts`. `dispatch-lane.ps1` publishes the ordinary
schema-4 launch owner and starts `long-product-gate.ps1` as its tracked child.
The supervisor accepts only the exact launch id, lane, worktree, branch and
head supplied by that dispatch. It invokes only
`invoke-heavy-verifier.ps1 -Gate test:scripts`; it accepts no command, script,
or payload from the host.

The supervisor first publishes a `long-product-gate/v1` pending result at the
launch-id-derived runtime path. Its terminal verifier result is atomic and is
not a pass: the outer dispatch may mark it `passed` only after exact launch
owner cleanup succeeds. Missing, torn, foreign, late, interrupted, or
nonzero results are incomplete. A host watch expiry never kills the product
child and never turns an incomplete result into a pass.

Only the existing verifier owns admission, census, slot, Git identity, clean
tree, receipt and child cleanup authority. The supervisor adds no timeout,
census clock, retry, slot, reclaim, scheduler, or product command behavior.
