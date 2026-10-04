# Premise Freshness Contract v1

`PREMISE_FRESHNESS_CONTRACT_VERSION: premise-freshness/v1`

This contract defines the read-only predicate that runs immediately before a
decision recommendation could be adopted. It never adopts, closes, comments
on, edits, or otherwise mutates a GitHub resource. Its only outcomes are
`adopt` (the supplied authority proves every named premise fresh) and
`refuse` (all other cases).

## Candidate schema

The input schema is `premise-freshness-request/v1`. Its `candidate` object has
these required fields:

- `decision.repository`, `decision.issueNumber`, and
  `decision.filingInstant` identify the candidate decision. The filing instant
  is retained only as evidence and is never a comparison fallback.
- `analysisInstant` is the persisted instant at which the recommendation's
  analysis was written. It must be an ISO-8601 instant with an explicit UTC
  offset.
- `premiseRules` is a non-empty list. Every entry has a non-empty `name`, a
  `repository` in `owner/name` form, and a positive `issueNumber`.

The comparison instant is always `analysisInstant`. A missing or malformed
analysis instant refuses; the checker must never substitute the decision
filing time, issue update time, invocation time, or current time.

The request's `authority` array contains one
`premise-freshness-authority/v1` record for each named premise. Production
callers may instead inject a transport that returns the same record per
premise. The pure predicate treats transport failures and missing or duplicate
records as unavailable authority.

## Authority and pagination

Authority is the injected human repository-owner identity for the premise
repository: `repository.nameWithOwner` plus `repositoryOwner.login`. The
human authority is intentionally distinct from the GitHub namespace owner
(for example, the `chase-sets` organization in `chase-sets/chase-sets`).
A worker, bot, collaborator, organization member, decision author, or premise
author does not inherit that authority. GitHub logins and repository
identities are compared case-insensitively because GitHub identity is
case-insensitive; no display name or email participates.

Every authority record identifies the exact premise issue and supplies three
bounded collections: `comments`, `bodyEdits`, and
`supersedingDecisions`. Each collection has `items` and a pagination envelope:

```json
{
  "schemaVersion": "github-pagination/v1",
  "mode": "all-pages",
  "complete": true,
  "truncated": false,
  "pageCount": 1,
  "itemCount": 0
}
```

The acquiring transport sets `complete: true` only after following pagination
to the terminal page. `mode` other than `all-pages`, a next page not read, a
provider cap, a false or missing completeness bit, a truncation bit, or a count
mismatch is non-authority and refuses. An empty collection is valid only when
that complete envelope proves `itemCount: 0`.

The comments collection consumes exactly these fields from every item returned
by GitHub's paginated issue-comments endpoint:

- `id`
- `html_url`
- `body`
- `user.login`
- `created_at`
- `updated_at`

Both timestamps are required ISO-8601 instants. `updated_at` cannot precede
`created_at`. Other endpoint fields are outside this contract and confer no
authority.

`bodyEdits` is an injected, completely paginated set of body-edit events. Each
item carries `id`, `html_url`, `field` (exactly `body`), `actor.login`, and
`created_at`. `supersedingDecisions` is an injected, completely paginated set
of native/structured supersession links. Each item carries `issueNumber`,
`html_url`, `linked_at`, `linkedBy.login`, and a structured `supersedes` target
(`repository`, `issueNumber`). Prose such as "supersedes #123" is not a link.

## Amendment shapes

Only an act authored or performed by the repository owner can amend a premise.
The four amendment shapes are:

1. **New comment.** An owner-authored semantic Amendment comment whose
   `created_at` is later than the analysis instant.
2. **Edited comment.** An owner-authored semantic Amendment comment whose
   `updated_at` is later than both its `created_at` and the analysis instant.
   This catches an amendment folded into an older comment.
3. **Premise-rule body edit.** A body-edit event performed by the repository
   owner whose `created_at` is later than the analysis instant.
4. **Linked superseding decision.** A structured supersession link performed
   by the repository owner whose `linked_at` is later than the analysis
   instant and whose target is the named premise rule.

A semantic Amendment comment has `Amendment` followed by a positive integer at
the start of its first nonblank line, optionally preceded by a Markdown heading
marker (for example, `Amendment 5 (...)` or
`## Amendment 5 implementation clarification`). Matching is case-sensitive.
The word "amendment" elsewhere in prose, an `Addendum`, and an unnumbered
heading do not match.

When several amendments qualify, the checker reports the earliest event after
the analysis instant, with premise name/repository/issue, amendment shape,
timestamp, and source identity. Comment refusals additionally report the exact
comment `id` and `html_url`.

## Raw JSON resource policy and refusal precedence

The public JSON entrypoint applies these fixed v1 resource limits before it
materializes a request:

- `MaxRequestBytes = 1048576` UTF-8 bytes.
- `MaxSupportedDepth = 256` object-or-array container levels, counting both
  objects and arrays and including the root container.

The raw-input check is one bounded O(n) lexical pass and does not build a JSON
tree. It is aware of JSON strings and escapes, decodes depth-1 root member names
under ordinal identity, counts both container kinds, and records the first
depth overflow with the root member value containing it. A value is in
authority scope only when it belongs to the unique decoded root member named
`authority`. Braces, brackets, quotes, and backslashes inside strings do not
affect depth or scope. Escaped names, including surrogate pairs, have the same
ordinal identity as their decoded spellings.

After that pass, bounded materialization uses `JsonDocument.Parse` with
`MaxDepth = MaxSupportedDepth + 2`, trailing commas disabled, and comments
disallowed. The policy pass guarantees that this implementation threshold is
unreachable. Duplicate-member validation then uses an explicit stack carrying
element, root, and authority-scope metadata. Every object's decoded ordinal
names are checked before its children are pushed, and children are pushed in
reverse so processing retains document order. Final request conversion sets
`ConvertFrom-Json -Depth (MaxSupportedDepth + 2)` explicitly; it never relies
on that command's default depth.

Every raw-input rejection exits with `refuse`, never `adopt`, and applies this
fixed precedence:

1. More than `MaxRequestBytes` -> `REQUEST_MALFORMED`.
2. A duplicate decoded root member -> `REQUEST_MALFORMED`. This outranks depth,
   so duplicated root `authority` members never establish authority scope.
3. More than `MaxSupportedDepth` -> `AUTHORITY_MALFORMED` when the first
   overflow is inside the unique root `authority` value; otherwise
   `REQUEST_MALFORMED`. This resource decision outranks later syntax failure.
4. Malformed or truncated JSON, including a non-object root ->
   `REQUEST_MALFORMED` uniformly, even when truncation is inside `authority`.
5. A duplicate below the root -> `AUTHORITY_MALFORMED` in unique-root-authority
   scope; otherwise `REQUEST_MALFORMED`.

## Fail-closed verdict

The output schema is `premise-freshness-verdict/v1`. `adopt` is returned only
when every required field is well formed, every named premise has exactly one
complete authority record, every bounded collection proves all-pages
completeness, and no qualifying amendment is later than `analysisInstant`.

All unavailable, malformed, truncated, unpaginated, ambiguous, or empty-
premise inputs return `refuse` with a stable named `reason`; they never throw
an adopt-shaped default. Amendment refusal uses
`PREMISE_AMENDED_AFTER_ANALYSIS` and includes the rule/source evidence described
above. Other stable reasons distinguish `EMPTY_PREMISE_RULES`,
`AUTHORITY_UNAVAILABLE`, `AUTHORITY_MALFORMED`, `AUTHORITY_TRUNCATED`,
`AUTHORITY_UNPAGINATED`, and `REQUEST_MALFORMED`.
