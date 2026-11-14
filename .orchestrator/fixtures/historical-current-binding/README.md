# Historical current-binding control inputs

These are original raw Git blobs, not reconstructed or current substitutes.
The seven product scripts are from product commit
`50a920d4cede95309dff8c4aead17ed43859ccee`. The pre-fix controller wrapper
is the exact original blob already named by `Invoke-CurrentBindingControls`.
Only these eight source blobs are archived; no private Git history is included.
`Read-CurrentBindingFixture` verifies each raw blob before decoding and copying
it into the test's disposable repository. The ordinary native before/after
controls and their expected outcomes are unchanged. The manifest is closed.

- scripts/verify-static-scoped.mjs | blob `bb77106882a590253500d446ff431510b94e37c8`
- scripts/verify-static-surfaces.mjs | blob `2e09c0db0d328846596cfd3586ea7d6f4582b896`
- scripts/change-scope.mjs | blob `bb07241ebd9865a9753e057f652a514bf3c38fbe`
- scripts/e2e-suites.mjs | blob `5ec9ff849d3f4dbc1c79ec9db8ae7fb12424adcb`
- scripts/lib/repo.mjs | blob `5be342b36d2f9eb5855853859082f8028f7cc043`
- scripts/lib/risk-policy-v1.mjs | blob `70a865109d246d4c9287a0b1224b2f9e9ec0ad12`
- scripts/lib/heavy-slot.mjs | blob `30327bd78fe8eb15130f63faafee42172b4d8eed`
- .orchestrator/invoke-heavy-verifier.ps1 | blob `3d1a71ebd741e78cb018e16e758971272ba31fb7`
