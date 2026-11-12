# Paid and one-shot external actions

Read before the named side effect. Hard gates in the core still apply.


Use `one-shot-action-brief.ps1 -Template`: goal/target, owner authorization,
per-action attempt caps, total spend/currency (zero without authorization),
environment/credential boundary, TCGplayer prohibition, ordered steps with
worst-case cost/units, one result file. No execution packet/rebind, START-file
or extra custody artifact. Brief grants no authority: use an already authorized
operator/tool. Review once for production/money, otherwise none; review deltas
only when reviewed bytes change.

For irreversible provider mutations, use the provider's precise dry-run/plan
before the authorized live window. Do not substitute synthetic provider facts.

Before each side effect read actual deployed SHA for Chase Sets deployments;
record it and cumulative attempts/spend/outcome. Wrong environment or missing
required identity stops action. Do not pin/rebind to main or hold ready PRs;
assess remaining steps if deployment changes, without resetting limits.
Cite limit-owner authorization. Count every submitted attempt, failures and
prior runs included; reserve units/worst-case cost before issuing. Reservation
write failure means no action. No automatic retries outside same caps. Unknown
submission, missing history or unbounded cost stops further actions; reconcile
read-only, never replay to discover outcome. Rename/replan/review/replacement
cannot reset caps; only limit owner authorizes increase. Keep secrets out.

```one-shot-action-brief
Goal: <bounded outcome and target environment/service>
Hard limits: <owner authorization; attempt cap per action; total spend cap and currency, including zero>
Boundary: <staging only when required; no secrets in brief/results or credential access>
TCGplayer: never contact its servers or store/use its credentials.
Steps: <ordered commands/clicks; worst-case cost and attempt units for each>
Result file: <one path for execution-time deployed SHA, attempts, spend, outcome>
```
