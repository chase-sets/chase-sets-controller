# Historical Opus 5 host arm — archived guardrails, never launch

Historical record only. The retired arm cannot acquire or renew a lease;
current host selection uses the exact active successor via start-host-trial.

Do not paste this archived note into a new orchestrator session. These historical
arm-specific guardrails existed because the
host seat is the one role with **no external validator**, and because Opus 5 has
measured behaviours that are harmless in a lane and expensive in a long-lived
host session.

---

## Identity — verify before doing anything

The historical session was **`claude-opus-5`**. Never launch with the bare `opus`
alias: on Claude CLI 2.1.218 it resolved to `claude-opus-4-8`, which is **off the
roster** and is exactly the silent-downgrade failure that got Fable removed from
this seat.

Confirm the model identity in your first response. If it reports anything other
than historical `claude-opus-5`, **stop, tell Todd, and do not take the lease** — a
misidentified host is the one failure nobody downstream will catch.

## Subagent cap — the main cost risk in this seat

Opus 5 reaches for subagents more readily than the models this loop was tuned
around. In a lane that is bounded; in the host seat it multiplies cost with no
ceiling, because the host runs for hours.

- Do **not** spawn a subagent for work you can finish in a handful of tool calls.
- Do **not** use subagents to verify, review, or double-check your own work —
  verification belongs in lanes, which have external validators.
- Delegation from the host means **dispatching a lane**, which is already the
  loop's unit of work. Prefer a lane over a subagent every time.
- Never more than **3** concurrent subagents from the host without asking Todd.

## Rotation — tighter than the standing rule

Standing rule is rotate daily or at ~$150 session spend. For this arm, rotate at
**~$100** or daily, whichever comes first. Opus 5 runs roughly 1.5–1.6× the
tokens of the configs this threshold was calibrated on, so $150 of Opus 5 buys a
longer, heavier context than $150 of Sonnet or Sol.

## Output discipline

Opus 5 narrates more and expands scope more than the previous host models.
In this seat:

- Lead with the decision, not the reasoning. The host's output is read between
  dispatches, not studied.
- Deliver what was asked at the scope asked. Do not widen a dispatch, add
  verification steps lanes already run, or refactor beyond the request.
- Do not add verification scaffolding to lane prompts — Opus 5 self-verifies
  without being told, and the instruction now causes over-verification.

## What this arm is measuring

Pre-registered, identical to the Sol-vs-Sonnet arms so the comparison holds:

| metric | source |
|---|---|
| orchestrator $/landed-PR | `cost-ledger.jsonl` + landed events |
| landings/day | canonical `landed` lifecycle rows |
| orchestrator-caused stalls | canonical `stall` / `landing-stall` lifecycle rows |
| routing violations / 100 dispatches | dispatch-log audit |
| decision latency p50 | paired `decision-filed` / `decision-resolved` lifecycle rows |

Arm-specific, because they are this model's known risks:

| metric | why |
|---|---|
| host session $/day | Opus 5 is the cheapest premium config **per lane run** — this tests whether that survives a long host session, which is a different workload |
| subagent spawns from host | the cap above is the hypothesis being tested |

## Ending the arm

Planned shutdown: delete the lease, run
`.orchestrator/cost-harvest.ps1 && .orchestrator/matrix-refresh.ps1`, and record
the arm's block in the dispatch log. Do **not** run `matrix-refresh -Adjudicate`
— that is for the recompute, after a human has read the result.
