## Why

`BeamPeerGrantStore` currently reports lock contention, helper failures, unsafe custody, and unexpected exceptions as `:beam_peer_grant_store_invalid`. A valid first installation held beyond the lock bound can therefore look like corruption to a loader. The shared-lock precursor in PR #159 removed ordinary publication overlap but deliberately left this diagnostics and availability gap open.

This proposal defines the public error boundary requested by [issue #144](https://github.com/kapitan-ai/orchard/issues/144). It is a contract-only draft, not an implementation or a claim that the current store conforms. No production or test code lands until this change is accepted.

## What Changes

- Add `:beam_peer_grant_store_busy` for confirmed bounded acquisition contention and `:beam_peer_grant_lock_unavailable` for pre-operation helper/readiness failure.
- Keep both errors sanitized, preserve terminal unsafe or indeterminate custody failures, and preserve genuine absence and existing credential, lifecycle, and conflict results.
- Perform no automatic store retries. Callers own any separately explicit, bounded retry policy; this change adds no caller retry count or time budget.
- Require safe propagation through bootstrap, delivery, preflight, startup verification, and shared diagnostics without false missing results, new grant generations, duplicate durable effects, or transport fallback.

## Capabilities

### New Capabilities

- `peer-grant-store-errors`: stable sanitized store contention/helper classifications and caller-owned retry boundaries subordinate to `SPEC.md` §7.5.0.

### Modified Capabilities

None. Existing Runtime Endpoint transport and authorization requirements remain unchanged.

## Impact

- `SPEC.md` impact: amend §7.5.0 with error conditions, sanitization, no automatic retries, terminal custody precedence, and the two operator-facing vocabulary entries.
- No persistence format, lock inode, lock ownership, authorization, grant lifecycle, timeout value, transport selection, platform eligibility, packaging, or distribution-pause change.
- Later implementation must update the store's collapsed error propagation and test its public interfaces and callers. The current five-second native acquisition bound and six-second readiness guard are observations, not newly justified concurrency limits.
- [Issue #145](https://github.com/kapitan-ai/orchard/issues/145) remains residual after [PR #159](https://github.com/kapitan-ai/orchard/pull/159); do not repeat that implementation or claim completion here.
- [Issue #146](https://github.com/kapitan-ai/orchard/issues/146) remains dependent on #144 under the [superseding maintainer decision](https://github.com/kapitan-ai/orchard/issues/146#issuecomment-5174264398). Framing hardening and timeout qualification are later implementation, not authorized by this draft.
