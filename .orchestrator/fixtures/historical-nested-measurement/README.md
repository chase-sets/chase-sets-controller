# Historical nested-admission measurement inputs

Original raw Git blobs used by the ordinary measurement comparison, not
reconstructed or current substitutes. The wrapper is from controller commit
`177f2d55176d122b267444c3de240927f98285ff`; the client is the exact pre-7941
blob already pinned by `heavy-slot.test.ps1`. Only these two source files are
archived, not private Git history. Keeping them in the public tree makes the
existing content-addressed Git reads available on a fresh hosted checkout.
The ordinary measurement work, assertions and mutation cases are unchanged.

- .orchestrator/invoke-heavy-verifier.ps1 | blob `7aae059c121a433e628cf7935fb1e62e7f08b2ee`
- .orchestrator/heavy-slot.cjs | blob `71deeaae2c999d377d3d2ffe9b933219d62a06ff`
