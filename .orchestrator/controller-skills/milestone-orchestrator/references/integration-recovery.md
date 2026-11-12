# Interrupted canonical integration

Read only when the canonical integration helper stopped in a rebase, not for
ordinary dispatch. Runtime binding/admission is authoritative; this is usage guidance.

Use `dispatch-lane.ps1 -InterruptedIntegrationResumePath <binding>` only for its
closed `interrupted-canonical-integration/v1` or ordinary-author v2 binding.
The retained actual launch, start acknowledgement, request, canonical conflict
capture, branch/original head, onto, sequencer state and changed bytes must agree.
Runtime proves prior owners/possible descendants dead before admitting another
writer. A stale capture or transcript is not enough. Refusal preserves bytes.

Only the admitted implementation child resolves conflicts and calls
`rebase-integration.ps1 -ContinueInterruptedIntegration`. Never start another
rebase or normalize with abort/reset/stash/skip. Use current row-7 route and the
bound prior tuple as runtime requires; do not infer old routing identities.

Ordinary-author recovery requires `-NoPush` before mutation and the prompt's
`ordinary-integration-repair-authority/v1` exact repair/test paths. The admitted
owner finishes locally, adds plain repair/test commits, then publishes exactly
once through `-PublishInterruptedIntegration` under original-head lease. Runtime
checks each repair commit, not just net diff. Finished-unpublished is not complete.
Later stops need current checkpoint admission, not reuse of first-stop authority.
Resume grants no review, CI, provider, enqueue or landing authority.
