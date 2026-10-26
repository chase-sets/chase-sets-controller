---
name: orchestrator-shared
description: "Contract between the chase-sets product loop (milestone-orchestrator) and controller loop (controller-orchestrator): who owns which work, where issues are filed, release tags, the controller-defect hand-off, and the per-issue platform handoff. Read it with either orchestrator skill; it does not run a loop."
---

# Orchestrator Shared Contract

Two orchestrator threads share one backlog. The product loop runs
`milestone-orchestrator` from the product container. The controller loop runs
`controller-orchestrator` from the controller dev container. This contract
binds both loops and is stated only here.

## Two loops

The product loop builds the Chase Sets platform. It never edits, dispatches,
reviews, batteries or installs controller work: the `.orchestrator` runtime,
contracts and controller skills, and routing, velocity or capacity policy. It
never cuts batches, runs controller batteries or precursors, dispatches
controller reviews, or holds product lanes for controller work.

The controller loop owns controller work. Chase Sets product issues, product
lanes, the merge queue and deploys are not its work.

## Repository routing

Follow Repository routing in `main/docs/contributing/backlog-model.md`; work
for the other loop is filed on the other loop's repository. A standing
behavior change to the milestone-orchestrator skill or any controller runtime
is filed on `chase-sets/chase-sets-controller` for the controller loop; the
product loop never edits the skill or runtime. A Todd ruling that changes
runtime behavior goes to the controller loop the same way.

## Releases

A controller release is an annotated `controller-v*` tag on
`chase-sets/chase-sets-controller`. The controller loop authors, verifies and
tags it once its independent review passes and the release scan is clean; it
does not wait for Todd's approval. The controller loop never waits for a product
install: it keeps building and releasing, and tags may accumulate. The product
loop installs only the newest tag, at the start of the first cycle that can
take an install, with
`.orchestrator/install-controller-skills.ps1 -ReleaseTag <tag>`; it skips
older tags it never applied and does nothing else with releases. Release tags are the only install authority: never
install an untagged commit or by any other path, never edit the product
container checkout (it changes only through tag installs), and never copy a
live edit over a mismatch. Rollback is the product loop reinstalling the
previous tag with the same command.

## Defects

The product loop files a controller defect as an issue on
`chase-sets/chase-sets-controller` and continues product work. One exception:
a controller defect that blocks product delivery right now may be handled by
the product loop, first by reinstalling the previous release tag; a forward
fix follows the controller loop's release process. The controller loop treats
a controller defect filed by the product loop as top priority when it blocks
product delivery and fixes it forward through its release process. Each
product-side emergency rollback is logged by the product loop as
`escaped-defect`, and the controller loop finds its cause.

## Platform handoff

The product loop may hand individual low-priority Chase Sets issues to the
orchestration platform's Chase Sets loop (the platform loop) and take them
back. Labels and markers are the only transport between the product and
platform loops; milestones play no part. An issue is held while it carries
`dispatch:platform` without `dispatch:platform-return`, and returning while it
carries `dispatch:platform-return`.

- The product loop chooses handoffs and requests returns. Beyond the handoff
  and take-back writes below, it never touches an issue carrying either label,
  or that issue's PR or branch.
- The platform loop works only issues with `dispatch:platform` and without
  `dispatch:platform-return`.
- The controller loop owns `.orchestrator/platform-handoff.json`, the platform
  run, acknowledgment when no platform supervisor runs, and platform fixes
  from take-back causes.

`.orchestrator/platform-handoff.json` has exactly the fields `schemaVersion`
(`platform-handoff/v1`), `accepting` (boolean), `maxInFlight` (an integer of
zero or more), and `idleHours`, `maxHours` and `releaseHours` (positive
integers). Only the controller loop writes it. An absent, unreadable or
invalid file means not accepting.

Authorities come from complete paginated reads, and an incomplete read makes
no handoff and no clock-based take-back for that issue this cycle. Label age
is the newest `LabeledEvent` for `dispatch:platform`; return age is the
newest `LabeledEvent` for `dispatch:platform-return`. Activity is the newest
of label age, the `updatedAt` of every PR in the issue's
`closedByPullRequestsReferences(includeClosedPrs: true)`, and comments
containing `<!-- loop-`.

Handoff: while the file is accepting and fewer than `maxInFlight` open issues
carry either label, the product loop adds `dispatch:platform` to the
lowest-ranked issue that has a current ready receipt (`issue-readiness/v1`),
`priority:p2` or `priority:p3`, a fast-path tier in its brief and one
`<!-- routing:` marker in its body; has no `risk:*`, `kind:ops` or
`kind:security` label, no open linked PR and no live lane; blocks no open
issue; and has never had a `platform-take-back` marker.

Take-back: the product loop takes back an open held issue for one of these
reasons, named in its marker:

- `needs-replan`: the issue gained `status:needs-replan`.
- `needs-operator`: the issue gained `status:needs-operator`.
- `handoff-closed`: the handoff file is not accepting.
- `idle`: no activity for `idleHours`.
- `max-age`: label age is older than `maxHours`.
- `priority`: the issue is now `priority:p0` or `priority:p1`.
- `dependent`: the issue now blocks an open issue.

The merge queue is no exception. A take-back writes in order, skipping each
step already done: (a) one comment `<!-- platform-take-back: {"version":1,"reason":"<reason>"} -->`
with a one-line cause; (b) add `dispatch:platform-return`; (c) remove
`dispatch:platform`. Each cycle, a take-back marker newer than the newest
`dispatch:platform` labeled event resumes at the first undone step, unless a
release marker newer than it exists.

Acknowledgment is the holder's alone: the live platform supervisor, or the
controller loop when none runs. In order, the holder (1) confirms by a fresh
read that no linked platform PR is in the merge queue, dequeuing and
re-reading until it is out or merged; (2) removes `dispatch:platform`; (3)
posts `<!-- platform-released: {"version":1,"by":"platform"|"controller","outcome":"released"|"merged"} -->`,
with `merged` when the platform PR merged; (4) removes
`dispatch:platform-return`.

The product loop owns the issue again only when neither label is present and
a release marker is newer than its take-back. It then delivers normally: a
closed issue needs nothing; an open platform PR is adopted after an exact-head
independent review, or closed. A return not acknowledged within
`releaseHours` of its return label gets one controller defect from the
product loop, and the issue stays untouched.
