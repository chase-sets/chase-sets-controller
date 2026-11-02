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
