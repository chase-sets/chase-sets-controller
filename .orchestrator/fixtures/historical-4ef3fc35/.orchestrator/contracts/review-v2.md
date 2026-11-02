# Review Contract v2

`REVIEW_CONTRACT_VERSION: review-contract/v2`

Review the exact dispatched head independently. Do not modify the branch beyond
the bounded mechanical remedies described under Patch attachments. Execute
every reproduction you rely on. Style, preference, and unrelated debt never
block. Quality dimensions block only on the objective sub-cases defined in
`contracts/quality-v2.md`, read beside this contract at the dispatched
controller head; every other observation on a dimension is a non-blocking
finding with a stable ID.

For an ordinary PR review, the dispatch supplies both opaque attempt identities:
the reviewer's current attempt/transcript identity and the author attempt whose
artifact is being reviewed. Repeat them exactly in the completion report. They
must differ even when the requested model names differ. Never infer either
identity from a model family, process, worktree, or review prose.

For a strict controller review, repeat the complete immutable dispatch tuple:
positive issue, exact controller head, distinct author/reviewer attempts,
governing/shadow/advisory authority, lane, transcript, exact reviewer and author
models, effort, routing row, placement, and harness. Authority is fixed at
dispatch. Shadow and advisory receipts are evidence only: they never authorize
or block installation. Emit the terminal only after its exact dispatch and use
the closed controller receipt schema; free text never supplies identity.

Controller review launch uses `dispatch-lane.ps1 -LaneRole review
-ReviewTarget controller -ControllerIssue <issue> -ControllerHead <exact-head>
-AuthorAttempt <author> -ReviewerAttempt <reviewer> -AuthorModel <exact-model>
-ReviewAuthority governing -Row <row> -Placement <placement>` together with the
ordinary harness/model/effort/prompt/worktree/label inputs. The lane is the
canonical worktree leaf and the transcript is exactly `<Label>.jsonl`. Before
launch, the host calls canonical `log-event.ps1 -Log dispatch -Kind dispatch
-ControllerHead <exact-head>` with that complete tuple (using `-Issue`, `-Lane`,
`-Transcript`, and `-Model` for the reviewer). No `-AuthorEffort` or terminal
fields belong to this closed dispatch. The existing strict reducer must find
one unique exact in-flight dispatch before plan, ownership, isolation,
transcript, or harness side effects. Missing, duplicated, conflicting, terminal,
or mismatched history refuses. A controller source tree, structurally identified
by its tracked controller battery entrypoint, cannot omit the controller target.
Product review and planning retain their existing behavior. Never write a late
strict tuple to repair this release's governing review launch.

The single Todd-authorized #7978 historical generic-dispatch linkage uses only
`log-event.ps1 -Kind controller-review-audit-correction`, with the complete
strict tuple, `-OriginalDispatchRawSha256`, `-OriginalTerminalRawSha256`, and
`-OperatorAuthority Todd:https://github.com/chase-sets/chase-sets/issues/7972#issuecomment-5657749132`.
No other authority reference, candidate, or original pair is accepted. The
exact candidate is `7e256a9dfa52ee907a1585e2989e8475858a1224`; dispatch timestamp
`2026-09-13T22:43:54.868Z` and strict terminal timestamp
`2026-09-13T22:55:44.031Z` retain native precision. Original dispatch SHA256 is
`79135c2de2c9e1346471243bd53ca85adf161670271f38086b56318e73733cf3`; terminal SHA256 is
`6321dd4b64a51e50594ce806bf99b212fe88befd0a7e02c2ec40216503141153`.
Hashes identify the immutable
UTF-8 original row bytes excluding the line terminator. The producer rechecks
the entire bounded canonical history under its append lock. Both original rows
must be unique and independently agree on issue, lane, transcript, reviewer
configuration, and every other structured identity the generic row contains.
The strict terminal supplies the exact candidate and participants; explicit
operator authority supplies the missing historical link, never generic prose.
Original dispatch line and timestamp must precede the terminal, which must
precede the correction. The correction is stamped now and stays a distinct
audit event; original bytes, order, and timestamps are never changed. Duplicate
corrections, ambiguous originals, noncausal order, or tuple mismatches refuse.
Reduction exposes both original hashes and correction provenance. It grants no
new verdict or install authority beyond the unambiguous original terminal's
ordinary governing disposition. Without this exact correction, strict pairing
still rejects the generic dispatch. This API is not a review-start workaround.

Semantic implementation identity and strict participant identity are separate.
The semantic implementation G1 identity and attempt count persist across a
repair; review, repair, and planning rounds do not consume another implementation
attempt or change the fourth-attempt step-back trigger. The lane name
identifies the current author or reviewer execution and is unique while live
through ownership-v4, not globally single-use across historical receipts.
Historical attempt fields remain readable audit evidence and are never
rewritten, but reuse on an unrelated issue/head cannot poison a current
controller candidate. Author and reviewer values remain distinct inside one
tuple, and its causal dispatch and terminal repeat the same exact
issue/head/lane/transcript tuple. Record semantic G1 in separate implementation
bookkeeping, never as an extra field in the closed strict rows.

## Planning/review handoff

A lane must not launch model CLIs or subprocess reviewers itself; any required
independent review returns to the host for a canonical attributed dispatch after
full artifact author/repair-history eligibility checks. Output from a bypass is
non-governing evidence, never review or admission authority. An
`unsupported_encrypted_delegation` adapter failure followed by an
attempted native-CLI fallback must be reported as `PENDING_HOST_REVIEW`,
never a semantic verdict. Do not execute
that fallback. Report the failure, required review scope and complete author/repair
history to the host. Only a host-dispatched eligible review can supply independent
review authority; record its exact dispatch/receipt binding, never invent a verdict.
`PENDING_HOST_REVIEW` is a handoff, not a review disposition or semantic receipt.

Count every in-body brief repair in that model's artifact repair history. If no
admitted independent brief reviewer remains, never add a sweep or cleanse history.
For a nonterminal, outcome/decision/acceptance-preserving repair, the host may apply
FINAL `brief-sweep2-authority-decision-r1`'s standing proof route: bind the completed
repair, current body/dependencies and full findings in a causal exception record;
retain trusted readiness and ordinary admission; use a row-qualified author and a
fresh code-history-independent reviewer for one complete exact-head implementation
review that challenges the whole brief and all findings before ready/landing.
This is not a brief semantic PASS. Terminal re-entry, changed semantics,
missing authority or no eligible implementation reviewer remain outside this
route and return to independent decision. No attempt, blocking-round or landing
rule changes.

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
evidence. Batch every confirmed blocker into this one result. State
`COMPLETE_SWEEP: true`.

A repair re-read is a delta review. It cites the predecessor PASS or
BLOCK_FIXABLE receipt on the ancestor head, verifies that the diff between that
head and the reviewed head is confined to the prescribed remedies, and inspects
only those hunks and their direct callers. The predecessor sweep plus the delta
is the complete sweep of the reviewed head, so the report states
`COMPLETE_SWEEP: true` and `REVIEW_SCOPE: DELTA <predecessor receipt id>`. A
diff that reaches outside the prescribed remedies, or a repair without a
predecessor receipt, requires `REVIEW_SCOPE: COMPLETE`.

A conflict-free rebase needs no delta re-read only when the canonical
`rebase-only-continuation/v1` producer binds the positive PR, exact source PASS
receipt and reviewed head, new head and base, integration lane, no conflict
resolution, and every ordered old/new commit pair with equal stable patch ids.
That source PASS plus continuation is exact-new-head authority after required CI
passes at the new head. A conflict, changed or empty patch range, wrong or
omitted source PASS, malformed row, or ambiguous history fails closed. A
conflict resolution is read as `REVIEW_SCOPE: DELTA <source PASS receipt id>`
over only the resolved hunks and their direct callers; it is never promoted to
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

## Required completion report

```text
REVIEW_CONTRACT_VERSION: review-contract/v2
DISPOSITION: PASS | BLOCK_FIXABLE | BLOCK_REPLAN | SKIP
COMPLETE_SWEEP: true
REVIEW_SCOPE: COMPLETE | DELTA <predecessor receipt id>
EXACT_HEAD: <40-char sha>
REVIEWER_ATTEMPT: <opaque dispatched attempt/transcript identity>
AUTHOR_ATTEMPT: <opaque author attempt identity>
REQUESTED_MODEL: <exact version>
REPORTED_MODEL: <exact version>
BLOCKING_FINDINGS: <count>
FINDING_IDS: <comma-separated IDs or none>
NON_BLOCKING_FINDINGS: <count>
NON_BLOCKING_IDS: <comma-separated IDs or none>
REVIEWER_PATCH: false | true
QUALITY_PROFILE: prototype | product-feature | core-library | hot-path | migration | contract
QUALITY_VERDICT:
G0: PASS <not-built list verified> | BLOCK_REPLAN <simpler shape>
<one line per quality-v2 key: KEY [weight]: little=PASS|BLOCK <ids>|NOTE <ids> ; much=PASS|BLOCK <ids>|NOTE <ids> ; N/A <reason>>
FINDINGS:
<structured findings, or "none">
VERIFICATION:
<commands/probes and observed results>
```

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
