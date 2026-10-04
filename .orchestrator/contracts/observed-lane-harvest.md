# Observed Lane Times

`log-event.ps1` keeps `ts` as the machine-stamped write time. Optional
`-ObservedEndAt` is accepted only on `lane-complete`, `lane-blocked`,
`review-complete`, `decision-resolved`, `verify-complete`, and `repair-complete`.
Optional `-ObservedStartAt` is accepted only on `dispatch`. Both require a lane,
an explicit ISO UTC instant (`Z` or `+00:00`), a time no later than now or the
row's own `ts`, and `-ObservedEvidence`. Supported citations are
`report-mtime:<source>`, `transcript-ctime:<source>`, or
`transcript-lastwrite:<source>`. Citations are retained, not file-existence
claims: captured evidence may live in a retained input file.

End validation uses the latest lane dispatch's `observedStartAt` when present,
otherwise its `ts`. Start validation refuses a time earlier than any prior
row's `ts` for the same lane/attempt. Existing `attemptId` or `reviewerAttempt`
identities scope the check when present; unattributed prior rows remain
lane-scoped rather than being guessed to belong to another attempt.
Both checks run under the existing append mutex and
refuse incomplete history. Refusals preserve all prior bytes. No row is rewritten.
Velocity uses the observed time for lane hours, action times, dispatch ages,
controller ownership observations, PID-launch windows, and terminal re-entry
comparisons. Velocity orders lane lifecycle rows by effective observed time
(stably for equal instants); physical ledger order and velocity-observation
`ts` remain write-time facts.

## Harvest Plan

The host runs the installed harvester after independent review/install. The
author does not run it against the live ledger. It only emits PowerShell calls:

```powershell
pwsh -NoProfile -File .orchestrator/harvest-observed-lanes.ps1 `
  -LanesPath "$env:TEMP/unharvested-lanes-1840.json"
```

Input is the captured list shape, with unique lane names and positive issues:

```json
[
  {
    "lane": "synthetic-8615",
    "issue": 908615,
    "dispatchRowUtc": "2026-10-04T10:00:00Z",
    "reportMtimeUtc": "2026-10-04T12:00:00Z",
    "transcriptCreatedUtc": "2026-10-04T10:00:00Z",
    "lateDispatchRow": false
  }
]
```

The captured report mtime is always the end source, following Todd's 18:45Z
addition to #8615, not the issue body's older transcript-lastwrite preference.
For `lateDispatchRow: true`, emit one closed observation-only
`lane-time-correction/v1` row, followed by one bound ordinary `lane-complete`
(`lane-time-harvest/v1`). Never emit another dispatch. The retained capture
proves transcript creation as start and report mtime as end. The flag alone
is not authority. Normal captured lanes emit only their bound completion.

`-HistoryPath` defaults to the adjacent read-only dispatch ledger. Private tests
also supply `-LedgerPath` to put `-OutFile` in the generated calls; production
omits it. Planning reads complete history and captures but writes nothing and
executes nothing. Lane sorting and apostrophe escaping are deterministic.
Missing evidence reports `HARVEST_EVIDENCE_MISSING` and emits no calls for that
lane. Invalid capture structure/times or incomplete history refuses the whole
plan before output. Target-specific contradictions report `HARVEST_REFUSED`
before emitting calls for the remaining valid lanes. A refused lane is not a
successful harvest. `-Verbose` reports call and refused-lane counts.

## Correction Boundary

`-ObservationSchema`, `-LaneTimeTarget` and `-LaneTimeSource` are closed JSON
parameters of `log-event.ps1`. Correction rows have only `ts`, `kind`, `issue`,
`lane`, `observationSchema`, `dispatchTarget`, `sourceCapture`,
`observedStartAt` and `observedEvidence`. Bound completion rows replace start
with `observedEndAt`. Neither accepts outcomes, PRs, models, review authority,
or decision payloads. The correction is unrelated to controller audit repair.

`dispatchTarget` binds the unique original raw SHA-256, exact original `ts`,
and an `attempts` object containing every present `attemptId`, `reviewerAttempt`
and `authorAttempt`, preserving absent legacy fields as absent. Unknown attempt
fields refuse rather than being dropped. `laneHistorySha256` binds the complete
same-lane evidence census at planning, excluding only the observation variants.
An intervening launch/terminal therefore makes the plan stale. Existing distinct
attempts can be paired individually, but ambiguous legacy launches refuse.
Recorded corrections/completions are checked at their own append boundary;
later legitimate lane reuse does not retroactively invalidate those facts.
Unbound terminals cannot close the corrected latest dispatch, even without an
observed end. Raw conflicting terminal data yields a named velocity gap.
Routing metadata is not another launch. The original row is never rewritten.

`sourceCapture` has exactly `path`, `sha256`, `lane`, `startField`, `endField`
and `dispatchField`. The content digest and selected lane/field citation bind
the retained capture, not a mutable path alone. Validate captured lane, issue,
dispatch timestamp, start and end, including any recorded canonical observed
launch or terminal contradiction. Vanished original transcripts/reports need
not be recreated; retain the actual capture. A missing or modified retained
capture fails closed. Unknown nested fields and wrong types refuse.

Only this explicit correction permits an end before original dispatch write
time: `start <= end <= terminal.ts <= now`, `start <= originalDispatch.ts`.
The correction's own `ts` is still its current machine write time. Ordinary
unmarked prior-row refusals stay unchanged. Validation and replay run under the
existing append lock. Exact replay visibly returns `LANE_TIME_ALREADY_RECORDED`
without writing; conflicting replay refuses. Interrupted correction/completion
replay writes only the missing valid step. No separate lock or JSONL writer.

Velocity projects the correction onto its original dispatch before stable
effective-time ordering and pairs the completion with that exact raw identity,
not a later launch. It preserves original timestamps, issue/configuration,
attempts and capture annotations, 48-hour clipping, and legacy fallback.
Malformed observation data names gaps and invalidates lane-hour/share evidence,
never presenting a partial share as healthy. No observation supplies review or
verify PASS, decision authority, process exit/vacancy, terminal re-entry,
landing authority, or attempt-ceiling authority. Hosted controller CI is the
continuation's execution proof; independent exact-head review and installation
must precede host-only application of the retained live capture.
