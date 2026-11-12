## ADDED Requirements

### Requirement: Distinct bounded acquisition failures

For install and load, `BeamPeerGrantStore` SHALL return `{:error, :beam_peer_grant_store_busy}` for confirmed exhaustion of its bounded contention wait without acquisition, and `{:error, :beam_peer_grant_lock_unavailable}` when a helper on a supported lock backend cannot start or establish valid readiness before the store operation begins. Helper startup/I/O failure, unexpected exit, invalid readiness, and readiness deadline expiry without confirmed contention SHALL use lock unavailable rather than claiming corruption or absence. A missing helper executable on a supported backend SHALL remain lock unavailable even when operator repair is required; unsupported hosts SHALL instead remain terminal store invalid with cause `:unsupported_host`. A generic nonzero exit or elapsed time alone SHALL NOT establish contention. This changes `SPEC.md` §7.5.0.

Both supported backends SHALL identify contention using exit 75 before readiness: macOS SHALL retain `lockf -s`, and Linux SHALL pass `--conflict-exit-code 75` to `flock`. Exit 75 SHALL establish contention only when received before both the readiness marker and expiry of the outer readiness guard. After readiness, that status belongs to the wrapped command and SHALL NOT be classified as acquisition contention. An outer guard expiry SHALL remain lock unavailable even if exit 75 arrives later; generic exit 1 SHALL NOT establish contention.

#### Scenario: Valid installer outlasts acquisition wait
- **WHEN** install or load cannot acquire the existing parent lock within the bounded contention wait and that contention timeout is confirmed
- **THEN** the store SHALL return `{:error, :beam_peer_grant_store_busy}` without starting the protected store operation
- **AND** it SHALL NOT report a missing or corrupt grant solely because acquisition timed out

#### Scenario: Helper cannot establish readiness
- **WHEN** a helper on a supported backend cannot start, marker I/O fails, an unexpected exit occurs, readiness is invalid, or the readiness deadline expires without confirmed contention
- **THEN** the store SHALL return `{:error, :beam_peer_grant_lock_unavailable}` before the protected operation begins
- **AND** diagnostic text SHALL NOT promise that retry will succeed without operator intervention

#### Scenario: Contention status arrives after the guard
- **WHEN** the outer readiness guard expires before a valid readiness marker or confirmed contention status is received, and the helper subsequently reports exit 75
- **THEN** the result SHALL remain `{:error, :beam_peer_grant_lock_unavailable}`
- **AND** the late status SHALL NOT retroactively establish store busy

#### Scenario: Host has no supported lock backend
- **WHEN** the host OS has no supported lock backend
- **THEN** the store SHALL return terminal `:beam_peer_grant_store_invalid` with sanitized cause `:unsupported_host`
- **AND** it SHALL NOT classify this as a repairable missing helper on a supported backend or imply platform eligibility

#### Scenario: Supported backend has no helper executable
- **WHEN** a supported host is missing its helper executable, including Linux without util-linux
- **THEN** the store SHALL return `{:error, :beam_peer_grant_lock_unavailable}`
- **AND** diagnostic text MAY indicate that operator repair is needed without exposing host details

### Requirement: Terminal custody and existing results retain precedence

Unsafe persistent state and unclassified or indeterminate custody failures SHALL remain terminal, never either retryable acquisition error. Loss of lock continuity after the protected operation begins, when observed by the post-operation continuity check, SHALL override every operation result with `:beam_peer_grant_store_invalid`, including operation errors and absence; a terminal custody error SHALL NOT be overwritten by a retryable helper result. Only when no such loss is observed SHALL genuine absence remain `:beam_peer_grant_missing` and existing credential, lifecycle, and conflict errors retain their classifications. Those terminal errors SHALL NOT be retried under this contention policy. This preserves and clarifies the fail-closed atomic custody boundary in `SPEC.md` §7.5.0.

Before spawning a lock helper, validation of an existing regular, same-owner candidate SHALL require both owner read and owner write permission bits. A missing bit SHALL return terminal `:beam_peer_grant_store_invalid` with sanitized cause `:lock_file_open_failed`. Candidate absence SHALL remain permitted, and this check SHALL NOT require exact `0600` mode before permitted initialization narrowing. A helper open failure that passes candidate validation SHALL remain an unexpected pre-readiness exit classified as lock unavailable; native open-failure exit codes or stderr SHALL NOT establish terminal classification.

#### Scenario: Persistent custody is unsafe
- **WHEN** validation finds invalid ownership, a symlink, unsafe modes after permitted initialization narrowing, malformed persisted data, or tamper evidence
- **THEN** the store SHALL fail closed with its applicable terminal store or credential error
- **AND** it SHALL NOT return store busy or lock unavailable for that failure

#### Scenario: Existing lock candidate is unusable
- **WHEN** an existing regular, same-owner lock candidate lacks owner read or owner write permission, including mode `0000`
- **THEN** the store SHALL return terminal `:beam_peer_grant_store_invalid` with sanitized cause `:lock_file_open_failed` before spawning the helper
- **AND** diagnostic text SHALL describe an unusable candidate, not assert leaked grant material

#### Scenario: Helper cannot open a candidate that passed validation
- **WHEN** candidate validation succeeds but the helper exits before readiness because it cannot open the lock file
- **THEN** the store SHALL return `{:error, :beam_peer_grant_lock_unavailable}`
- **AND** it SHALL NOT infer permanence from the helper's native open-failure exit code or parse stderr for classification

#### Scenario: Helper disappears after publication starts
- **WHEN** loss of the helper after the protected operation begins is observed by the post-operation continuity check
- **THEN** the store SHALL return terminal `:beam_peer_grant_store_invalid` even if the grant file exists
- **AND** it SHALL NOT invite automatic replay through a retryable result

#### Scenario: Continuity loss follows an operation error or absence
- **WHEN** the protected operation returns an error or raw `:enoent` and the post-operation continuity check observes loss
- **THEN** terminal `:beam_peer_grant_store_invalid` SHALL override that result
- **AND** `load/3` SHALL NOT normalize the lost-lock result to `:beam_peer_grant_missing`

#### Scenario: Locked read establishes genuine absence
- **WHEN** load acquires the validated parent lock, establishes genuine grant absence, and no post-operation continuity loss is observed
- **THEN** it SHALL retain `:beam_peer_grant_missing` rather than either acquisition error

### Requirement: Store does not retry and callers own bounded policy

The store SHALL make no automatic retry of acquisition or the protected operation. One bounded acquisition wait and reconciliation of a single publication SHALL NOT be treated as retries. Callers SHALL explicitly decide whether to propagate or retry either acquisition error; any in-process caller retry loop SHALL have finite attempt and total elapsed-time bounds, revalidate the exact authorized generation and current lifecycle, and prevent duplicate durable side effects. An OTP supervisor restart or service-manager restart SHALL be a new invocation outside this caller-retry rule. Every invocation, including after restart, SHALL revalidate the exact authorized grant and SHALL NOT create a second durable side effect. Startup bootstrap SHALL retain `retrieval: :forbid`, loading rather than retrieving the grant after restart. This change SHALL NOT introduce a caller retry count or time budget or claim that existing supervision supplies the finite bound. This changes `SPEC.md` §7.5.0 without changing grant authorization or transport selection.

#### Scenario: Caller receives a retryable acquisition result
- **WHEN** a store call returns store busy or lock unavailable
- **THEN** that call SHALL end without a store-owned second attempt
- **AND** callers MAY propagate the result without retrying
- **AND** bootstrap, delivery, preflight, and startup verification SHALL preserve the classification rather than treating it as absence, a reason for new issuance/generation, or permission for transport fallback

#### Scenario: Caller separately elects bounded retry
- **WHEN** an in-process caller retry loop with an explicitly bounded policy makes another attempt after an acquisition failure
- **THEN** it SHALL revalidate the exact authorized grant and current lifecycle
- **AND** a completed identical installation SHALL remain idempotent without a second durable side effect

#### Scenario: Supervisor or service manager restarts an invocation
- **WHEN** an OTP supervisor or service manager restarts the process and a new store invocation begins
- **THEN** that invocation SHALL be outside the in-process caller-retry rule and SHALL revalidate the exact authorized grant without a second durable side effect
- **AND** startup bootstrap SHALL retain `retrieval: :forbid`, loading the grant or propagating missing without retrieving it
- **AND** supervision rate limits or service-manager throttling SHALL NOT be presented as the finite attempt and total elapsed-time bound required of an in-process retry loop

### Requirement: Error attribution is sanitized across surfaces

Both acquisition errors SHALL remain stable atoms. Returned results, shared operator diagnostics, logs, and telemetry SHALL expose no certificates, hashes, paths, PIDs, lock-file contents, raw helper output, grant material, raw exception terms, or other host detail. Any cause attribution SHALL use only the closed sanitized cause vocabulary below, not raw OS values. CLI and Console diagnostics SHALL preserve the distinction without adding transport fallback or weakening fail-closed behavior. This changes `SPEC.md` §7.5.0.

#### Scenario: Helper failure contains host-sensitive details
- **WHEN** failure evidence includes certificates, hashes, raw stderr, a local path, a process identifier, or lock-file data
- **THEN** the returned error SHALL contain only the stable applicable atom
- **AND** diagnostics, logs, and telemetry SHALL retain only a closed sanitized cause category

#### Scenario: Operator inspects acquisition failure
- **WHEN** the failure is surfaced through shared diagnostics in CLI or Console
- **THEN** `beam_peer_grant_store_busy` SHALL remain distinguishable from `beam_peer_grant_lock_unavailable`, `beam_peer_grant_store_invalid`, and `beam_peer_grant_store_conflict`
- **AND** no certificates, hashes, host detail, or raw grant/helper/exception data SHALL be exposed

### Requirement: Closed sanitized cause vocabulary

For the `SPEC.md` §7.5.0 store-error diagnostics contract, the permitted cause atoms SHALL be exactly:

- `:contention_timeout`
- `:helper_start_failed`
- `:helper_io_failed`
- `:helper_exited`
- `:readiness_invalid`
- `:readiness_deadline`
- `:unsupported_host`
- `:lock_file_open_failed`
- `:custody_validation_failed`
- `:lock_continuity_lost`
- `:store_operation_failed`

Cause attribution SHALL NOT extend this set through arbitrary OS values, exception terms, helper bytes, or dynamically constructed atoms. A cause label SHALL NOT by itself select a public error or authorize a retry.

#### Scenario: Attributing a helper or store failure
- **WHEN** a diagnostic, log, or telemetry event attributes a store failure to a cause
- **THEN** its cause SHALL be one of the enumerated atoms
- **AND** unclassified store-operation failures SHALL use `:store_operation_failed` without attaching raw evidence or changing the terminal error classification
