# Lane Process Priority

CONTRACT_VERSION: lane-priority/v1

The controller loop owns the git-ignored, machine-local
`.orchestrator/lane-priority.json`, alongside its `platform-handoff.json` policy:

```json
{ "schemaVersion": "lane-priority/v1", "priorityClass": "BelowNormal" }
```

Only `Normal`, `BelowNormal`, and `Idle` are supported. With no file the
default is `BelowNormal`. An unreadable file, malformed JSON, wrong schema,
or unsupported class falls back to `Normal` and never prevents dispatch.
`dispatch-lane.ps1 -PriorityClass Normal` overrides the file for one launch.
Higher classes are rejected as parameter values, and fall back to Normal in
the file. They must never let lanes outrank the orchestrator.

Immediately before its sole `Start-Process @startParameters`, the dispatcher
sets its own priority. Its earlier routing, admission, ownership census and
publication work retain the launcher's Normal priority. Windows children
inherit BelowNormal or Idle unless they explicitly choose another class.
The agent, its tool shells, Node processes and heavy-verifier children inherit
the selection. The `-LongProductGate` supervisor uses the same launch point;
its verifier and heavy work children also inherit it. Admission inside that
descendant verifier inherits too; no census deadline or admission rule changes.
The verifier job object sets KillOnClose, not scheduling priority.

The independent orchestrator cycle, reclaimer, stall watchdog, landing
preflight, board reconcile, release battery and separately host-launched heavy
admission do not inherit from the dispatcher and remain Normal. WMI and
`launch-retry.ps1` ancestors are not reprioritized. No existing process tree is
retuned when the file changes; the setting applies only on the next launch.

Durable launch specs (`watchdog-lane-<label>.json`) contain
`priorityClass` and `prioritySource`. Sources are `parameter`, `file`, `default`,
or `fallback:<reason>` (`schemaVersion`, `priorityClass`, or
`unreadable-or-invalid-json`). The durable spec preserves the evidence after
ownership cleanup. The file is never installed or committed with a release.
