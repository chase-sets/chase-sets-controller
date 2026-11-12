# Review Contract v2

`REVIEW_CONTRACT_VERSION: review-contract/v2`

Review the exact dispatched head independently. Do not modify the branch beyond
the bounded mechanical remedies described under Patch attachments. Execute
every reproduction you rely on. Style, preference, and unrelated debt never
block. Quality dimensions block only on the objective sub-cases defined in
`contracts/quality-v2.md`, read beside this contract at the dispatched
controller head; every other observation on a dimension is a non-blocking
finding with a stable ID.

Use one focused review in a fresh session that did not author the change.
The host chooses the reviewer; model family, prior participation in another
session, lane names and attempt-history lists do not determine independence.
Never review output authored in the current session.

Ordinary and controller PRs use the same receipt: PR, reviewed head, reviewer
model, verdict and finding counts. Record it with
`log-event.ps1 -Log dispatch -Kind review-complete -Pr <pr>
-ReviewedHead <head> -Model <reviewer-model> -Outcome <verdict>
-Blocking <count>`. `-Candidates` and `-NonBlocking` default to zero.
No contract marker, sweep flag, author identity, repair owner, attempt tuple,
prelog or route preparation is required. Legacy receipts remain readable audit
evidence without making their fields mandatory for new receipts.

Enqueue requires the live head to equal the reviewed head. The latest valid
review of that head supplies the verdict. A later PASS replaces an earlier
non-PASS; a new reviewed head needs no tree-identical recut to escape an old
verdict. Re-read only changed bytes and their direct callers after a repair.

A lane that cannot obtain a fresh non-author review returns the scope to the
host. Do not invent a verdict or launch an unapproved provider fallback.

## Disposition

Return exactly one:

- `PASS`: no confirmed blocking correctness, security, or objective quality
  finding.
- `BLOCK_FIXABLE`: every blocker is implementation-shaped and repairable
  without changing issue decisions, acceptance criteria, or authority
  assumptions.
- `BLOCK_REPLAN`: at least one blocker is specification/feasibility-shaped,
  depends on unavailable authority evidence, or lacks a bounded safe remedy.
- `SKIP`: only when the orchestrator explicitly authorized the trivial-diff
  review skip.

Plain `BLOCK` is invalid.

## Complete sweep

Do not stop after the first confirmed finding. Inspect the whole declared
footprint, relevant callers/contracts, tests, omitted states, and claimed
evidence. Batch every confirmed blocker into this one result.

A repair re-read is a delta review. It cites the predecessor PASS or
BLOCK_FIXABLE receipt on the ancestor head, verifies that the diff between that
head and the reviewed head is confined to the prescribed remedies, and inspects
only those hunks and their direct callers. The predecessor review plus the
delta covers the reviewed head. Inspect newly changed bytes outside the
prescribed remedies as well; unchanged bytes need no repeat review.

A conflict-free rebase needs no delta re-read only when the canonical
`rebase-only-continuation/v1` producer binds the positive PR, exact source PASS
receipt and reviewed head, new head and base, integration lane, no conflict
resolution, and every ordered old/new commit pair with equal stable patch ids.
That source PASS plus continuation is exact-new-head authority after required CI
passes at the new head. A conflict, changed or empty patch range, wrong or
omitted source PASS, malformed row, or ambiguous history fails closed. A
conflict resolution receives a delta review over only the resolved hunks and
their direct callers; it is never promoted to
a fresh complete sweep merely because the rebase changed the commit SHA.

For a controller repair, only a governing `BLOCK_FIXABLE` predecessor with at
least one named finding may select the ancestor head as the release-battery
`-BaselineHead`. A test/skill/contract-only repair diff selects the prose plan;
any runtime-script change selects the full plan. The initial candidate always
uses the installed controller baseline and full runtime proof. Malformed,
missing, non-ancestor, non-fixable, or finding-less predecessor evidence cannot
reduce the battery scope.

## Blocking finding

Give every blocker a stable ID (`F1`, `F2`, ...), then include:

1. `REPRODUCTION`: exact command/probe executed and observed failure.
2. `ROOT_CAUSE`: why the behavior fails.
3. `SURFACE`: exact files, symbols, states, or contracts involved.
4. `PRESCRIBED_REMEDY`: smallest bounded correction.
5. `REGRESSION_PROOF`: focused evidence that fails before and passes after. When
   it asserts a fact owned by an external authority, include the exact probe and
   observed output at the granularity consumed; a coarser fact is not authority
   for a finer assertion. Never use a real external identity with altered facts
   to satisfy an assertion; genuinely synthetic controls use unmistakably
   synthetic identities and are labeled synthetic.
6. `PRESERVE`: behavior already verified correct that the repair must not
   disturb.
7. `CONFIDENCE`: high/medium plus residual uncertainty.

If a safe prescribed remedy cannot be stated, use `BLOCK_REPLAN`. Do not return
an aspirational suggestion as a fixable blocker.

## Patch attachments

A reviewer applies a bounded mechanical remedy (pins, counts, generated
outputs, lint, and the analogous fixes named in the dispatch) directly on the
reviewed branch, lists each applied hunk under `REVIEWER_PATCH: true`, and
leaves validation to hosted CI on the pushed head. The reviewer never validates
its own patch and never repairs a semantic finding; a semantic remedy returns
to the author as a `BLOCK_FIXABLE` finding. When the dispatch withholds
mutation, attach the mechanical remedy as a literal patch instead.

## Quality verdict

Every review answers the `G0` gate, names the brief's quality profile, and
returns one verdict line per pair key of `contracts/quality-v2.md`, in its
table order: SCOPE, ROBUSTNESS, DEPTH, READABILITY, TESTS, OBSERVABILITY,
SECURITY, PERFORMANCE, ROLLOUT, CONSISTENCY, EXPERIENCE, LANGUAGE. Each line
carries the profile's weight for that key and scores both sides, too little
and too much: `PASS` with the evidence examined, `BLOCK` with the finding IDs,
`NOTE` with the non-blocking IDs, or `N/A` naming the absent surface. A side
blocks only on its stated sub-case and only at the weight the profile allows,
and every `BLOCK` finding meets the blocking finding shape above. A `G0`
failure is `BLOCK_REPLAN`. Non-blocking findings use IDs `N1`, `N2`, ...
and each names its surface and a one-line remedy; they are mandatory to write
and never a reason to block. Where the PR body carries a `## Quality Packet`,
verify each of its claims; never adopt one.

## Completion receipt

The receipt has five concepts; findings may include explanatory prose below it.

```text
PR: <positive PR number>
REVIEWED_HEAD: <40-char sha>
REVIEWER_MODEL: <exact model version>
VERDICT: PASS | BLOCK_FIXABLE | BLOCK_REPLAN | SKIP
FINDING_COUNTS: blocking=<count>, nonBlocking=<count>
```

The host checks the reviewer is a fresh session that did not author the change.
Detailed findings and verification commands support the review, but are not
extra receipt fields or launch gates.

The requested and reported model versions must match exactly. Sonnet 5 is
retired for new writes; pin `claude-sonnet-5-5`. Historical Sonnet 5 receipts
remain readable without relabeling or evidence transfer. Sol 6 (`gpt-6-sol`)
is likewise retired for new writes; pin `gpt-6.1-sol`. Family aliases
are invalid. `claude-opus-4-8`, `claude-opus-5`, and the GPT-5.6 models are
retired for new dispatch; their evidence does not transfer to Opus 5.5 or
GPT-6 successors. Historical receipts retain the original exact identities.
`claude-fable-5` is retired and never
selectable; pin `claude-fable-5-1`, and Fable 5 evidence does not transfer to
it.
