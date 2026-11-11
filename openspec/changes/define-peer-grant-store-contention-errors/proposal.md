## Why

`BeamPeerGrantStore` currently reports lock contention, helper failures, unsafe custody, and unexpected exceptions as `:beam_peer_grant_store_invalid`. A valid first installation held beyond the lock bound can therefore look like corruption to a loader. The shared-lock precursor in PR #159 removed ordinary publication overlap but deliberately left this diagnostics and availability gap open.

This proposal defines the public error boundary requested by [issue #144](https://github.com/kapitan-ai/orchard/issues/144). It is a contract-only change, not an implementation or a claim that the current store conforms. No production or test code lands until this change is accepted.

## What Changes

- Add `:beam_peer_grant_store_busy` for confirmed bounded acquisition contention and `:beam_peer_grant_lock_unavailable` for pre-operation helper/readiness failure.
- Require confirmed native contention signals on both supported backends before readiness and outer guard expiry; a late signal remains lock unavailable.
- Reject an existing lock candidate missing owner read/write bits before helper spawn as terminal store invalid; helper open failures after validation remain lock unavailable without inferring permanence from native exit codes. Unsupported hosts stay terminal, while missing helper executables on supported backends remain lock unavailable and may need operator repair.
- Keep both errors sanitized and preserve terminal unsafe or indeterminate custody failures. Observed post-operation continuity loss overrides every operation result with terminal store invalid; otherwise preserve genuine absence and existing credential, lifecycle, and conflict results.
- Perform no automatic store retries. Callers own any separately explicit, finitely bounded in-process retry loop; none exists today, and this change adds no caller retry count or time budget. Supervisor/service-manager restarts are new invocations outside that rule, but every invocation must revalidate the exact authorized grant and create no second durable side effect. Retain load-only startup bootstrap with `retrieval: :forbid`; current supervision does not supply the finite retry bound.
- Require safe propagation through bootstrap, delivery, preflight, startup verification, and a new Node-store-to-CLI/Console shared diagnostics surface without false missing results, new grant generations, duplicate durable effects, or transport fallback. Include terminal store-invalid and store-conflict errors in the operator-facing vocabulary and define a closed sanitized cause-atom set.

## Capabilities

### New Capabilities

- `peer-grant-store-errors`: stable sanitized store contention/helper classifications and caller-owned retry boundaries subordinate to `SPEC.md` §7.5.0.

### Modified Capabilities

None. Existing Runtime Endpoint transport and authorization requirements remain unchanged.

## Impact

- `SPEC.md` impact: amend §7.5.0 with error conditions, sanitization, no automatic retries, terminal custody precedence, and operator-facing acquisition and terminal store vocabulary entries.
- No persistence format, lock inode, lock ownership, authorization, grant lifecycle, timeout value, transport selection, platform eligibility, packaging, or distribution-pause change. Later implementation must add candidate owner read/write validation before helper spawn and the Linux explicit contention-exit argument.
- Later implementation must update the store's collapsed error propagation and test its public interfaces and callers. The current five-second native acquisition bound and six-second readiness guard are observations, not newly justified concurrency limits.
- [Issue #145](https://github.com/kapitan-ai/orchard/issues/145) remains residual after [PR #159](https://github.com/kapitan-ai/orchard/pull/159); do not repeat that implementation or claim completion here.
- [Issue #146](https://github.com/kapitan-ai/orchard/issues/146) remains dependent on #144 under the [superseding maintainer decision](https://github.com/kapitan-ai/orchard/issues/146#issuecomment-5174264398). Framing hardening and timeout qualification are later implementation, not authorized by this contract change.
