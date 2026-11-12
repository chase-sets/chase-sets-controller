# Recovery after review or CI failure

Read for the named failure classification or planning re-entry.

Classify each blocking review/red required job: mechanical repair in place;
tooling/environment resumes same configuration after native blocker; known
implementation remedy to author; brief/slice/design defect replans at ISSUE/
SET/EPIC; external authority needs native blocker/operator; product priority/
scope conflict goes to Todd. Escalate recurring causes, not counts. Keep repairing
shrinking failures, but when the same failure persists across three consecutive
heads the host steps back to replan/change approach, even if others shrink.
No step-back review, decision lane or threshold receipt. Ask Todd only for his
actual decision, never an attempt ceiling.

For an owned issue, `BLOCK_REPLAN` or an ISSUE/SET/EPIC brief, slice or design
defect: add `status:needs-replan` to each affected owned issue and
dispatch a `planning` lane under `contracts/planning-repair-v1.md` with the assigned
ISSUE, SET or EPIC recovery level. The label invalidates ready/terminal status
until current-brief readiness and independent semantic PASS restore re-entry.
Never label/mutate platform-held issues; apply shared take-back first.

Attempts are telemetry: a pushed head counts only after hosted CI or exact-head
review verdict. Local/preparation/harness/tooling stops do not count; replacement
never resets consumed history. Dispatch counts are not prerequisites/permission
decisions. Paid/one-shot limits remain binding. Planning re-entry uses
`contracts/planning-repair-v1.md`: a new causal recovery hypothesis, not a new
model/elapsed time, plus trusted readiness and independent semantic PASS on the
current brief. No automatic terminal park.
