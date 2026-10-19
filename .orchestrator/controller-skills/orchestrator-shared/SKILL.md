---
name: orchestrator-shared
description: "Contract between the chase-sets product loop (milestone-orchestrator) and controller loop (controller-orchestrator): who owns which work, where issues are filed, release tags, and the controller-defect hand-off. Read it with either orchestrator skill; it does not run a loop."
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
tags it, and Todd approves it. The controller loop never waits for a product
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
