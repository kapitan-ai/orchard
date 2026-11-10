## Context and status

This is a proposed contract, with no production or test changes. `SPEC.md` §7.5.0 remains the apex contract. Acceptance of this exact change is required before code lands; drafting the amendment does not assert implementation conformance or authorize implementation, issue closure, publication, or merge.

The mapping below was checked against `apps/orchard_node_agent/lib/orchard/node/beam_peer_grant_store.ex` and `apps/orchard_node_agent/test/orchard/node/beam_peer_grant_store_test.exs`. Function names, rather than line numbers, identify the reviewed paths. Both install and load take the same validated parent lock before accessing grant custody. No second lock inode, unlocked inspection, or polling is proposed.

## Decisions

### Two public errors, no automatic store retry

Use two sanitized atoms rather than the generic error plus internal causes. `:beam_peer_grant_store_busy` means confirmed exhaustion of the acquisition contention wait. `:beam_peer_grant_lock_unavailable` means failure to establish the helper/readiness protocol before the store operation begins. A retry is eligible, not guaranteed to work: a missing executable may need operator repair. A single bounded acquisition wait is not an automatic retry.

Callers may propagate either failure without retrying. Any later caller retry policy must explicitly bound attempts and total elapsed time, revalidate the exact authorized generation and current lifecycle, and preserve idempotence. This proposal deliberately does not select one caller retry or a twelve-second budget. Bootstrap must not interpret either result as absence and retrieve another grant. Preflight and startup verification must remain fail-closed; delivery must preserve the selected descriptor and generation. No Runtime Endpoint operation falls back to gRPC because of these errors.

### Terminal custody takes precedence

Do not relabel generic filesystem errors or arbitrary rescued exceptions as contention. Known unsafe custody and failures that leave custody or exclusion indeterminate stay terminal. In particular, losing the helper after the operation starts is not equivalent to failing to acquire it: publication may already have occurred without provable uninterrupted exclusion. The conservative proposed mapping keeps that path terminal, even if a subsequent independently invoked install could succeed idempotently.

This preserves permitted initialization narrowing: install may narrow a same-owner directory or regular lock candidate under the existing rules; load does not repair an unsafe store. A stale regular lock file and its contents are not evidence that a process still holds the kernel lock. Do not infer contention from contents or PIDs.

### Sanitized attribution

Returned results contain only stable atoms. Diagnostics, logs, and telemetry may distinguish a closed set of causes such as contention timeout, helper start failure, helper I/O failure, readiness protocol failure, readiness deadline, custody validation failure, and lock continuity loss. Never attach arbitrary OS terms, helper bytes, exception terms, paths, PIDs, lock-file contents, grant material, or other host detail. Cause attribution does not introduce additional public retryable errors or make a terminal failure retryable.

## Current failure-path mapping

Except for the explicitly retained results below, these paths currently collapse to `:beam_peer_grant_store_invalid`. This table describes the proposed result, not current runtime behavior.

| Current path or condition | Proposed result and boundary |
| --- | --- |
| `validate_grant/3`, its rescue, invalid controller UUID in `load/3`, or `ensure_current/2` with invalid window types | Retain terminal `:beam_peer_credential_mismatch`; identifier, binding, canonical name, contract, window, and secret/hash checks are not contention. |
| `ensure_current/2` before lock, before publication, on load, or before install return | Retain `:beam_peer_grant_not_active` or `:beam_peer_grant_expired`; no retry under this contention policy. |
| `prepare_identity_root/1`: missing/inaccessible root, invalid type/mode, stat failure, exceptions | Terminal store invalid; missing identity root is not a missing grant. |
| `lock_process/1`: unsupported OS | Lock unavailable before operation; does not grant that OS platform eligibility. |
| `validate_lock_candidate/2`: wrong owner, non-regular candidate, symlink, or lstat failure other than absence | Terminal store invalid; do not mask unsafe or indeterminate custody as helper failure. Candidate absence is allowed, not an error. |
| `open_lock_port/2`: executable absent/unstartable, `Port.open` failure, marker submission false/exception | Lock unavailable when attributable to helper startup/I/O before operation; unrelated or unclassified exceptions remain terminal. |
| `await_lock/1`: native helper reports a positively identified contention timeout before readiness | Store busy. Nonzero exit alone is insufficient; distinguish the helper's documented contention outcome from other failures without parsing or exposing arbitrary output. |
| `await_lock/1`: unexpected exit not confirmed as contention | Lock unavailable before operation, not proof of a busy store. |
| `await_lock/1`: fragmented/coalesced/malformed or unexpected output currently fails the exact-message match | Lock unavailable if a valid readiness exchange cannot be established. Later framing hardening must accept valid fragmentation/coalescing while rejecting unexpected/trailing bytes; this draft does not implement the parser. |
| `await_lock/1`: outer readiness guard expires without a confirmed contention outcome | Lock unavailable. Elapsed time alone cannot establish kernel contention. |
| `finish_lock_acquisition/3`: chmod or post-acquisition lock file type/uid/mode validation fails | Terminal store invalid, even after a valid marker; lock helper success does not prove safe custody. |
| `with_store_lock/4`: final `Port.info` is absent after `operation.()` | Terminal store invalid due to lost lock continuity. Do not promote a published-but-unconfirmed result to retryable or overwrite an operation's terminal custody failure with a helper error. |
| `close_lock_port/1`: close raises/throws during best-effort teardown | Currently swallowed, with no independent returned failure. Do not invent a retryable result from this cleanup path or replace a terminal result. |
| `prepare_store/3`, directory lstat/mkdir/narrowing/validation, parent directory sync, creation hook non-`:ok`/raise/throw | Terminal store invalid. Existing `mkdir` `:eexist` reconciliation and permitted narrowing are initialization, not retry loops or busy errors. |
| `load_under_lock/5`: absent store/grant or read `:enoent` after acquiring lock and validating parent custody | Retain `:beam_peer_grant_missing` for genuine absence, never for an uncompleted acquisition or publication wait. |
| `load_under_lock/5`: unsafe directory/file, read failure other than absence, malformed JSON/decoded fields, controller mismatch, or other unclassified result | Terminal store invalid, except existing explicit credential and lifecycle results propagated by `load/3`. |
| `decode_persisted/1`, `decode_datetime/1`, optional datetime decoding: malformed hash encoding/timestamps/shape | Terminal store invalid, including exceptions caught at the public boundary. A decodable but invalid secret/hash binding on load remains credential mismatch. |
| `sweep_stale_temporaries/3`, `remove_stale_temporary/3`, `normalize_remove/1`: listing failure, unsafe entry, failed cleanup | Terminal store invalid; a disappeared temporary (`:enoent`) remains successful cleanup. |
| `load_existing/2`, `publish_or_load/4`: absent grant, exact existing grant, different existing grant | Absence continues to publication, exact equality succeeds idempotently, different grant retains terminal `:beam_peer_grant_store_conflict`; none is busy. Read/validation/decode failures remain terminal store invalid. |
| `write_private_file/3`, `write_open_file/4`: exclusive open, chmod, lstat, uid, write, file sync, or close failure | Terminal store invalid, including temporary-name collision and cleanup after failed write. These are not evidence of acquisition contention. |
| `publish/4`, `link_and_cleanup/5`, `cleanup_failed_publish/2`: link failure or temporary cleanup failure | Terminal store invalid; publication may already exist. |
| Link `:eexist` and `load_after_publish_race/3` | Read and compare once: exact grant succeeds, different grant is terminal store conflict, failed/missing reload is terminal store invalid. Reconciliation of one publication is not automatic replay of the store operation. |
| `sync_directory/2`, `do_sync_directory/1`, `sync_open_directory/1`: directory open/sync/close or injected sync failure | Terminal store invalid; durability cannot be asserted. |
| `finish_install/5`, `rollback_expired_publish/6`: lifecycle failure after publication | Retain lifecycle error if newly published grant removal and directory sync succeed, or if grant was pre-existing; validation/removal/sync failure during rollback is terminal store invalid. |
| Public `install/5` and `load/3` rescue/catch, invalid `load/3` arguments, unclassified operation failures | Terminal store invalid unless positively classified at the helper boundary above. Invalid `install/5` argument types have no matching clause today; changing that API is outside this taxonomy. |

### Signals that cannot identify the underlying cause today

Every returned path above has a proposed disposition, but today's undifferentiated helper exit status branch cannot prove contention versus helper malfunction, and its six-second guard cannot prove whether the kernel lock was busy. The exact-message branch cannot distinguish valid split/coalesced marker delivery from malformed output. Later implementation must establish deterministic native-helper outcomes and bounded framing; it must not guess `store_busy` from elapsed time or a generic nonzero exit.

The final `Port.info` check likewise cannot determine when exclusion was lost relative to publication. Proposed disposition: terminal store invalid. Acceptance review must explicitly confirm this conservative post-operation boundary; if helper loss after mutation should instead be retryable, that requires a separate proof of safe custody and idempotent replay, not a blanket atom replacement.

## Existing tests and later regression coverage

Existing tests cover exact/idempotent installation, first-store serialization, load/publication overlap, genuine absence, unsafe load custody and symlinks, malformed stored data, temporary cleanup failures, cross-VM exclusion, stale lock reuse, owner death, bounded native arguments, missing helper, non-regular lock candidates, creation hook failure, helper exit before teardown, secret/hash mismatch, lifecycle checks and rollback, and certificate-authenticated client behavior.

The contention and missing-helper tests currently assert generic store invalid; later implementation must change those expectations and add the missing load and framing/error-propagation cases rather than fossilize the residual result. The helper-exit-before-teardown test already demonstrates that a grant can exist when the operation reports failure. Preserve that terminal safety case. This proposal does not change the test file or incorporate any concurrent test-only fixes.

## Dependency reconciliation and alternatives

- [PR #159](https://github.com/kapitan-ai/orchard/pull/159) landed as an intentional partial precursor. Keep its single validated parent lock and exact-grant load behavior; the remaining long-wait diagnostics gap is this contract's concern, not a reason to replay the precursor.
- The [later decision on #146](https://github.com/kapitan-ai/orchard/issues/146#issuecomment-5174264398) supersedes its earlier independent-readiness clarification. This draft defines the public boundary but does not independently authorize framing work, raise timeout values, start implementation, or close #145/#146.
- Rejected alternative: retain only generic store invalid and add sanitized causes. That leaves callers unable to distinguish terminal custody from acquisition availability.
- Rejected alternative: add one caller retry within a twelve-second budget. Caller retry policy is not selected here; no such retry is introduced implicitly.

## Review questions

Confirm the conservative terminal classification for post-operation lock loss and the distinction between confirmed contention and an unconfirmed readiness deadline. These details refine the selected two-error/no-store-retry policy; no additional retry count or budget needs choosing to review this contract. Implementation still needs measured contention evidence and host-native exit/framing tests under #146, with public-interface and caller coverage under #144/#145.
