# Publishing or repairing a brief

Read only when publishing/editing/repairing brief bytes, not for code review or
routine dispatch. Existing `log-event.ps1` producer owns `brief-attribution/v1`;
this reference describes that API, not an extra review gate.

After exact readback, call the producer for intake/publication/edit/repair,
including reviewer in-body repair and host CAS transport:

```powershell
& "$O/log-event.ps1" -Log dispatch -Kind decision-resolved -Issue $issue `
  -BriefRevision ($target | ConvertTo-Json -Depth 20 -Compress) `
  -BriefAttribution ($attribution | ConvertTo-Json -Depth 20 -Compress) -NoBoard
```

`briefRevision`: positive `issue`, `artifact` (body or exact Packet identity),
immutable published `revision`, exact UTF-8 `bodySha256`, zoned `observedAt`.
`briefAttribution`: `operation`, `originalRowSha256`, `authors`, `host`,
`consumed`, `byteProof`, including null/empty values. Declare full consumed
ancestry, not deltas or inferred legacy edges. Unknown history is not empty.

Author tuple: `{issue,attemptId,dispatchRawSha256,evidenceRawSha256,model,effort}`.
Use original dispatch and actual author/repair evidence, retaining observed
effort or null. Raw row hashes omit line terminator. Host: `{model,effort,writing}`.
Consumed: `{issue,artifact,revision,bodySha256,attributionRawSha256}` pointing to
earlier validated declarations. Shared links are not authorship ancestry.

To transport lane-authored bytes record `attestation` with `-BriefEvidencePath
<author-report>`: one bound author, null host/original, empty consumed,
`byteProof:{reportSha256,bodySha256,attestorDispatchRawSha256}`. Inspect author's
report/transcript, not just host publication file. Publish matching bytes, then
`publication` with bound author, `host.writing:false` and
`byteProof:{attestationRawSha256}`. Host-written intake/edit without bound match:
`publication`, empty authors, `host.writing:true`, null byteProof. False writer
claims refuse `BRIEF_ATTRIBUTION_WRITER_CONFLICT`.

`retrospective` is truthful attribution stamped now, original row hash and exact
original tuples/artifact linkage, never backdated synthetic completion.
`participation` is nonwriting lifecycle: original row, empty authors/consumed,
null proof; not a publication exemption. Keep edits and historical conflicts.
Missing binding refuses `BRIEF_ATTRIBUTION_REQUIRED`; malformed/stale/causal
conflicts refuse `BRIEF_ATTRIBUTION_INVALID`. Repair the actual producer input,
do not bypass or turn old unknown history into review authority.
