# Native Scope Regression Inputs

Immutable offline inputs for `landing-preflight.test.ps1`. No test reads the
live controller runtime or the product checkout to replay this evidence.

- `goal-7969-change-scope-native-r1.log`: byte-identical historical native log;
  SHA256 `d22668fb8401274cf5921464d7269fcb0e58c94ad22947673178b43ca856203d`.
- `goal-7969-direct-enqueue-r1.json`: byte-identical historical journal;
  SHA256 `a2c737287e6b0b06f5f1fb5d24d7e306ca4eb74ff447f80a0565a3c8ef75bcba`.
- `change-scope.mjs`: product `scripts/change-scope.mjs`, Git blob
  `bb07241ebd9865a9753e057f652a514bf3c38fbe`.
- `e2e-suites.mjs`: product `scripts/e2e-suites.mjs`, Git blob
  `8053964a17a554f2c52e9c046f44b84299deaf05`.

Both producer files come from product commit
`2d77c295802c06eb73543a2010babe5d02392fb7`. The test verifies all four byte
identities before replay. Captures retain historical identities as evidence,
not current authority; the full native collector run was not retained.
The local attributes prevent checkout line-ending conversion.
