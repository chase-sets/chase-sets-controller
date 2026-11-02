# Quality Contract v2

`QUALITY_CONTRACT_VERSION: quality-contract/v2`

One rubric, checked at every stage. The planning pressure test judges the brief
against it, the author fills a Quality Packet against it before requesting
review, the independent reviewer returns a quality verdict against it, and the
weekly repo-wide review sweeps what remains. The bar is the repo's own
(`main/AGENTS.md`): the change achieves its intent, is correct, is as simple as
the intent allows, is safe, secure, and reliable, is performant, has a small
footprint, is a great user experience, is a deep module, is tested on every
surface it changes, and is written strictly in the ubiquitous language of its
bounded context and contracts.

Version 2 replaces v1's single-sided dimensions with tension pairs, a gate
answered before work starts, and a weight profile chosen per change. Each pair
names the cost of too little and the cost of too much, so a push on one side
shows as a cost on the other. Evidence, not taste: a side blocks only on its
stated reproducible sub-case and only at the weight its profile sets. Every
other observation is a non-blocking finding with a stable ID, mandatory to
write, never a reason to block, and consumed downstream. Style, preference,
and unrelated debt never block.

## Gate

`G0` is answered before anything else. Is there a simpler way to meet every
acceptance criterion? The planner constructs the strictly smaller plan at the
pressure test. The author answers again before building and lists what they
chose not to build, one reason each. The reviewer verifies the not-built list
against the diff. A simpler shape that meets every acceptance criterion and
was neither built nor rejected with a stated reason is `BLOCK_REPLAN`: it is a
planning defect, not an implementation one.

## Profiles

The brief declares one profile: `prototype`, `product-feature`,
`core-library`, `hot-path`, `migration`, or `contract` (cross-context events,
money, provider schemas). Weight semantics are fixed:

- `High`: both sides of the pair block on their sub-case.
- `Med`: the too-little side blocks; the too-much side is a note.
- `Low`: both sides are notes.

Two constants hold at every weight: confirmed incorrect behavior (SCOPE, too
little) and confirmed exposure (SECURITY, too little) always block. Nothing
else is High by default.

| Key | prototype | product-feature | core-library | hot-path | migration | contract |
|---|---|---|---|---|---|---|
| SCOPE | Med | High | High | High | High | High |
| ROBUSTNESS | Low | Med | High | Med | High | High |
| DEPTH | Med | Med | High | Med | Low | High |
| READABILITY | Low | Med | High | Med | Med | Med |
| TESTS | Low | Med | High | High | High | High |
| OBSERVABILITY | Low | Med | Med | High | High | High |
| SECURITY | Med | High | Med | Med | High | High |
| PERFORMANCE | Low | Low | Med | High | Med | Low |
| ROLLOUT | Low | Med | High | Med | High | High |
| CONSISTENCY | Low | Med | High | Med | Med | High |
| EXPERIENCE | Low | High | Low | Low | Low | Low |
| LANGUAGE | Med | High | High | Med | Med | High |

## Pairs

| Key | Pair | Too little blocks when | Too much blocks when | Evidence |
|---|---|---|---|---|
| SCOPE | Correctness vs scope | A named state or acceptance criterion behaves incorrectly or has no executed probe | A behavior ships that no acceptance criterion asked for | Criteria mapped to executed probes; diff against the brief's footprint |
| ROBUSTNESS | Simplicity vs robustness | A changed lifecycle has an unhandled state or transition | A guard, retry, or fallback names no concrete failure it prevents | State and failure-mode table; every guard annotated with its failure |
| DEPTH | Depth vs flexibility | An internal is exposed across a bounded-context boundary, or the public interface is wider than the behavior it hides | A new abstraction has one caller and no second real caller named | Interface added versus behavior hidden; caller count per abstraction |
| READABILITY | Readability vs brevity | Following one changed behavior from its entry point to its effect opens more than three non-test files, or a changed exported symbol states its behavior in none of its name, signature, types, or doc comment | A comment restates the adjacent code token for token, or a new identifier is an abbreviation found in neither the owning glossary nor the repo's convention list | Trace per changed behavior listing the files opened; exported-symbol table naming where each behavior is stated; comment diff; identifier list checked against the glossary |
| TESTS | Coverage vs test weight | A changed public surface has no test that exercises it | A test asserts only implementation details and would break on a correct refactor | Surface-to-test table; each new test named with the behavior it pins |
| OBSERVABILITY | Observability vs noise | A failure on a changed path produces no visible signal | Success on a changed path logs or alerts | Failure-signal table; log and alert diff |
| SECURITY | Boundary security vs friction | Input, authorization, secrets, or personal data cross a boundary unhandled | Defensive checks sit deep inside trusted code | Boundary inventory; checks placed at the boundary only |
| PERFORMANCE | Performance vs clarity | An unbounded query or per-item I/O on a measured hot path | An optimisation with no measurement on a path that is not hot | Bounds and indexes per query; measurement attached to each optimisation |
| ROLLOUT | Rollout safety vs cleanup | A schema, event, or contract change is not backward-safe or reversible where it matters | A dead path, flag, or legacy branch remains once safe to remove | Compatibility note per changed contract; removed-paths list |
| CONSISTENCY | Consistency vs improvement | A departure from local convention is unstated | A convention is followed where the brief called for a stated improvement | Departures listed with reasons |
| EXPERIENCE | Design-system fidelity vs local override | A changed UI surface misses a state (loading, empty, error, success) or uses the wrong design-system pattern | A local override or new component where the design system already has one | State inventory; component sources |
| LANGUAGE | Ubiquitous language vs convenience | A public name contradicts the owning glossary or a contract's published name | A new term is coined where the glossary already has one, or two names mean one thing | Public-name to glossary map; synonym check |

Public names are event types, commands, projections and their columns, routes,
contract fields, and user-visible copy. Internal identifiers that diverge are
non-blocking findings. A genuinely new concept with no glossary home is a
planning decision: the verdict is `BLOCK_REPLAN` under LANGUAGE, never an
invented term.

## Verdict

Every review answers the gate, names the profile, and returns one line per
key in table order:

```text
G0: PASS <not-built list verified> | BLOCK_REPLAN <simpler shape>
KEY [High|Med|Low]: little=PASS|BLOCK <F ids>|NOTE <N ids> ; much=PASS|BLOCK <F ids>|NOTE <N ids> ; N/A <absent surface>
```

`PASS` states the evidence examined. `BLOCK` names blocking findings that meet
the `review-v2.md` blocker shape and is valid only at the weight the profile
allows for that side. `NOTE` names non-blocking findings `N1`, `N2`, ... each
with its surface and a one-line remedy. `N/A` is valid only when the diff has
no surface on that pair and says which surface is absent. A verdict that
omits the gate, the profile, or a key, or that blocks on a side outside its
sub-case or weight, is malformed.

## Checkpoints

- **Planning.** Before dispatch the brief declares the profile, the simplest
  shape and its non-goals (G0), per-surface acceptance criteria (SCOPE),
  predicted footprint (SCOPE, DEPTH), the UI states it must render
  (EXPERIENCE), the data-path envelope it must respect (PERFORMANCE), the
  compatibility posture of any changed contract (ROLLOUT), and its terms with
  the owning glossary (LANGUAGE). The pressure test judges each.
- **Author.** The PR body carries a `## Quality Packet` that answers G0 with
  the not-built list, names the profile, and fills every key on both sides
  from the author's own probes. The reviewer verifies every claim and never
  trusts one.
- **Review.** The verdict block above is required in the completion report.
- **Consumption.** The controller files each non-blocking finding that names a
  public surface as a fixed-scope debt slice attached to the owning epic, one
  slice per reviewed PR; the remainder feed the weekly repo-wide review.
  Recalibration reads `NOTE` counts by key, side, and profile, and tunes the
  profile table on evidence every two weeks.
