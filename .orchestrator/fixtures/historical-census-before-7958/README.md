# Historical census discriminator sources

These are genuine original controller source bytes read from the authorized
product container, not a reconstruction or a policy mutant. No private Git
history is fetched or published. The public test uses only these files.

The C# source comes from commit `436a548cd8a1b9239ce43c4358a632c9d730261f`.
The guard comes from `d86f90db74e789f3966eda6f4d87a238d6e91577`, the direct
parent of census fix `8653b5cb1931b6e04a1973a23cb7dadbb23c392f`. That parent's
C# blob is identical to the original C# blob pinned here. The old test's guard
reference `0c99b24a4586a6c9d9990afa20ddec98e238f2dc` is unavailable in both
the public clone and retained product history. The genuine pre-fix parent
retains the original blanket CaptureDispatchCensus/SameDispatchCensus checks,
including the admission barrier seam. It is not a current-source substitute.

This two-file set replaces only the two historical source reads in each of
Invoke-CensusControls' baseline legs. The fixture still supplies its existing
candidate client, dispatch reader and inert native driver, as before. All
initial-body, lifecycle-change refusal, candidate acceptance, competing-claim,
body-count, selected-byte and exact-release assertions remain ordinary tests.
This is not a standalone archived runtime or a claim of native execution.

The loader verifies each raw Git blob before use. The manifest check verifies
the closed two-file inventory and raw blobs; `* -text` preserves their bytes.

- .orchestrator/heavy-nested-owner.cs | blob `006b4fe44619c001436b65ab5fc73fd083933513`
- .orchestrator/invoke-heavy-verifier.ps1 | blob `2242ae39894776c45709e4a5ecb67eeba536ee60`
