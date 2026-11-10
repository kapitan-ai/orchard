## ADDED Requirements

### Requirement: Distinct bounded acquisition failures

For install and load, `BeamPeerGrantStore` SHALL return `{:error, :beam_peer_grant_store_busy}` for confirmed exhaustion of its bounded contention wait without acquisition, and `{:error, :beam_peer_grant_lock_unavailable}` when a helper cannot start or establish valid readiness before the store operation begins. Helper startup/I/O failure, unexpected exit, invalid readiness, and readiness deadline expiry without confirmed contention SHALL use lock unavailable rather than claiming corruption or absence. A generic nonzero exit or elapsed time alone SHALL NOT establish contention. This changes `SPEC.md` §7.5.0.

#### Scenario: Valid installer outlasts acquisition wait
- **WHEN** install or load cannot acquire the existing parent lock within the bounded contention wait and that contention timeout is confirmed
- **THEN** the store SHALL return `{:error, :beam_peer_grant_store_busy}` without starting the protected store operation
- **AND** it SHALL NOT report a missing or corrupt grant solely because acquisition timed out

#### Scenario: Helper cannot establish readiness
- **WHEN** the helper cannot start, marker I/O fails, an unexpected exit occurs, readiness is invalid, or the readiness deadline expires without confirmed contention
- **THEN** the store SHALL return `{:error, :beam_peer_grant_lock_unavailable}` before the protected operation begins
- **AND** the result SHALL NOT assert that retry will succeed without operator intervention

### Requirement: Terminal custody and existing results retain precedence

Unsafe persistent state and unclassified or indeterminate custody failures SHALL remain terminal, never either retryable acquisition error. Loss of lock continuity after the protected operation begins SHALL remain `:beam_peer_grant_store_invalid`, and a terminal custody error SHALL NOT be overwritten by a retryable helper result. Genuine absence SHALL remain `:beam_peer_grant_missing`; existing credential, lifecycle, and conflict errors SHALL retain their classifications and SHALL NOT be retried under this contention policy. This preserves and clarifies the fail-closed atomic custody boundary in `SPEC.md` §7.5.0.

#### Scenario: Persistent custody is unsafe
- **WHEN** validation finds invalid ownership, a symlink, unsafe modes after permitted initialization narrowing, malformed persisted data, or tamper evidence
- **THEN** the store SHALL fail closed with its applicable terminal store or credential error
- **AND** it SHALL NOT return store busy or lock unavailable for that failure

#### Scenario: Helper disappears after publication starts
- **WHEN** the helper is lost after the protected operation begins and uninterrupted exclusion cannot be established
- **THEN** the store SHALL return terminal `:beam_peer_grant_store_invalid` even if the grant file exists
- **AND** it SHALL NOT invite automatic replay through a retryable result

#### Scenario: Locked read establishes genuine absence
- **WHEN** load acquires the validated parent lock and establishes genuine grant absence
- **THEN** it SHALL retain `:beam_peer_grant_missing` rather than either acquisition error

### Requirement: Store does not retry and callers own bounded policy

The store SHALL make no automatic retry of acquisition or the protected operation. One bounded acquisition wait and reconciliation of a single publication SHALL NOT be treated as retries. Callers SHALL explicitly decide whether to propagate or retry either acquisition error; any retry policy SHALL have finite attempt and total elapsed-time bounds, revalidate the exact authorized generation and current lifecycle, and prevent duplicate durable side effects. This change SHALL NOT introduce a caller retry count or time budget. This changes `SPEC.md` §7.5.0 without changing grant authorization or transport selection.

#### Scenario: Caller receives a retryable acquisition result
- **WHEN** a store call returns store busy or lock unavailable
- **THEN** that call SHALL end without a store-owned second attempt
- **AND** callers MAY propagate the result without retrying
- **AND** bootstrap, delivery, preflight, and startup verification SHALL preserve the classification rather than treating it as absence, a reason for new issuance/generation, or permission for transport fallback

#### Scenario: Caller separately elects bounded retry
- **WHEN** a caller with an explicitly bounded policy makes another attempt after an acquisition failure
- **THEN** it SHALL revalidate the exact authorized grant and current lifecycle
- **AND** a completed identical installation SHALL remain idempotent without a second durable side effect

### Requirement: Error attribution is sanitized across surfaces

Both acquisition errors SHALL remain stable atoms. Returned results, shared operator diagnostics, logs, and telemetry SHALL expose no paths, PIDs, lock-file contents, raw helper output, grant material, raw exception terms, or other host detail. Any cause attribution SHALL use only closed sanitized categories, not raw OS values. CLI and Console diagnostics SHALL preserve the distinction without adding transport fallback or weakening fail-closed behavior. This changes `SPEC.md` §7.5.0.

#### Scenario: Helper failure contains host-sensitive details
- **WHEN** a helper failure includes raw stderr, a local path, a process identifier, or lock-file data
- **THEN** the returned error SHALL contain only the stable applicable atom
- **AND** diagnostics, logs, and telemetry SHALL retain only a closed sanitized cause category

#### Scenario: Operator inspects acquisition failure
- **WHEN** the failure is surfaced through shared diagnostics in CLI or Console
- **THEN** confirmed contention SHALL remain distinguishable from helper unavailability and terminal custody errors
- **AND** no host detail or raw grant/helper/exception data SHALL be exposed
