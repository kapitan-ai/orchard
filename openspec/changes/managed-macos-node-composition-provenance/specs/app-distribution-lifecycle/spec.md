## ADDED Requirements

### Requirement: Managed Activation Uses Immutable Generations and One Pointer

Each source baseline and signed-prebuilt candidate SHALL reside in a distinct content-addressed immutable generation directory.
One validated relative active-generation pointer SHALL be the sole generation selector consumed by the stable bootstrap.
Activation and rollback SHALL change active content only by atomically replacing that pointer on the same filesystem with required durability barriers.

#### Scenario: Candidate activation changes the pointer

- **WHEN** the outgoing registered-process set is stopped with helper-issued outgoing-fence evidence and the candidate generation and activation authorization remain verified
- **THEN** lifecycle code SHALL atomically replace the active pointer with the exact candidate generation
- **AND** SHALL verify the observed pointer and generation before recording progress

#### Scenario: Pointer or generation is ambiguous

- **WHEN** the pointer is torn, missing, duplicated, out of root, contradictory, or names mutable or unverified content
- **THEN** lifecycle code SHALL classify the operation as uncertain and SHALL NOT start a process

### Requirement: Stable Bootstrap Owns Managed Recovery

The lifecycle coordinator, launch gate, recovery reader, active-pointer resolver, and privileged-helper client SHALL execute from the verified stable bootstrap outside replaceable generations.
The profile SHALL retain a durable managed-profile admission marker outside every generation and transition journal.
For the profile's entire admitted lifetime, the current schema-v1 app transaction and generic install, update, uninstall, start, stop, rollback, and recovery paths SHALL reject or delegate to the stable managed bootstrap, even when no transition generation is active.
The current schema-v1 app transaction and generation-owned code SHALL NOT recover or auto-restart a managed transition.
An unknown journal, bootstrap, helper, or protocol SHALL preserve general launch suppression.

#### Scenario: Current app transaction encounters managed state

- **WHEN** generic app lifecycle code observes the durable managed-profile marker, a managed-transition journal, or an active managed transition generation
- **THEN** it SHALL refuse generic recovery and loaded-service restoration
- **AND** SHALL leave the stable bootstrap in control

### Requirement: Managed Transition Has a Durable Monotonic Journal

The stable bootstrap SHALL maintain a versioned journal that binds operation ID, Controller transition generation, baseline and candidate identities, pointer observations, suppression generation, Worker Provider spawn-gate state, spawn reservations and their `reserved`, `spawned_blocked`, `bound`, `released`, or `reconciled` states, registered process identities, execution and fence epochs, consumed-or-rejected execution-grant IDs, channel-capability identities, Worker Runtime channel closure, generation-scoped socket removal, durably consumed privileged-command IDs and nonces with command kind, canonical-argument digest, and result identity, one-shot claim, provisional child, Controller host-arm token, host-arm evidence, pending-result consumption, exact-child enabled acknowledgement, Worker readiness evidence, exact active-generation launch policy, and monotonic phase.
The lifecycle SHALL durably record the state needed to interpret each external mutation before it reports corresponding progress.

#### Scenario: Recovery observes a supported journal

- **WHEN** recovery reads a valid managed journal after interruption
- **THEN** it SHALL re-observe Controller generation, pointer, generations, bootstrap, identity set, suppression, and process state before choosing an allowed next action

#### Scenario: Journal and observed state disagree

- **WHEN** any required journal evidence is missing, unsupported, stale, or contradictory
- **THEN** recovery SHALL preserve suppression and scheduler exclusion
- **AND** SHALL NOT infer completion

### Requirement: Candidate Starts Provisionally Under One-Shot Authorization

After candidate pointer activation, the lifecycle SHALL keep general launch suppression durable and SHALL mint one authorization bound to Node ID, operation, Controller transition generation, candidate generation, exact executable, bootstrap, launch label, nonce, and expiry policy.
The stable launch gate SHALL permit exactly one atomic claim and SHALL record the exact provisional child identity.
The profile-fixed system-domain launchd label SHALL name the stable bootstrap, which SHALL remain the launchd job root and `execve` the exact claimed Node Agent in place.
The helper SHALL persist the one-shot while the label is disabled, enable and bootstrap only that label, durably register the claimed job root, and disable the label again while the provisional child continues under stable-gate suppression.
An interrupted enable, bootstrap, claim, registration, or disable sequence SHALL not admit generation execution without the exact unclaimed authorization and SHALL reconcile to disabled state before recovery proceeds.
The provisional child SHALL NOT register normally, publish capacity, start Worker Provider execution, accept Runtime Endpoint work, serve requests, or become scheduler eligible.

#### Scenario: Matching candidate claims the one-shot

- **WHEN** the exact stable bootstrap starts the exact candidate under the current operation and generation
- **THEN** the launch gate MAY atomically claim the one-shot once and admit the child only in provisional mode

#### Scenario: Another claim or process appears

- **WHEN** a second, stale, replacement, wrong-generation, wrong-executable, or wrong-operation process attempts to claim or run
- **THEN** the lifecycle SHALL reject it and preserve general suppression

### Requirement: Host Arm Remains Provisional Until Controller Commit

General suppression and provisional restrictions SHALL remain active while the Controller verifies provisional evidence and terminalizes the transition.
The host SHALL consume a matching generation-bound Controller token only to persist idempotent `host_armed_pending_controller_commit` evidence for the exact provisional child.
Host arm SHALL NOT authorize normal serving, clear general suppression, or permit a replacement child.
The Controller SHALL first commit `controller_committed_pending_child_observation` while retaining maintenance and scheduler exclusion.
The exact child SHALL leave provisional mode only after consuming that authenticated pending result for the same Node, operation, and transition generation.
It SHALL enter exact-child enabled state while ordinary dispatch remains fenced.
Only then MAY the helper open the incoming Worker spawn gate for the exact child, generation, transition, and execution epoch.
The Node Agent SHALL reserve, spawn blocked, bind, and release the exact Worker Provider through the helper, establish the authenticated local channel, and acknowledge exact Worker identity, protocol compatibility, and a representative supported-model readiness or inference probe.
Terminal activation SHALL require a fresh Controller challenge of that same live Node Agent and registered Worker before a second transaction makes the Node active and clears exclusion.
After an accepted terminal result of `succeeded` or fully accepted `rolled_back`, the helper SHALL durably and idempotently replace transitional suppression with an exact active-generation launch policy bound to that result; until it observes that result and installs the policy, suppression SHALL remain fail closed, and stable-bootstrap recovery SHALL retry only the exact bound installation.
The same terminal result SHALL carry the accepted generation's new serving epoch, and ordinary grant issuance SHALL remain blocked until the helper durably reconciles that epoch and the Node Agent publishes matching epoch-readiness.

#### Scenario: Controller authorizes host arm

- **WHEN** the Controller returns a matching host-arm token
- **THEN** the host MAY record `host_armed_pending_controller_commit` only for the exact recorded provisional child
- **AND** SHALL report matching arm evidence without clearing suppression or provisional restrictions

#### Scenario: Token is missing, stale, or mismatched

- **WHEN** the token does not match the operation, transition generation, candidate, child, or bootstrap
- **THEN** the host SHALL keep general suppression active

#### Scenario: Pending result is lost or the child exits

- **WHEN** the pending result is lost, the Node Agent or Worker exits, Worker readiness is lost, or the host reboots before terminal success
- **THEN** the child SHALL NOT enter ordinary serving
- **AND** recovery SHALL close the incoming Worker gate, resubmit exact arm evidence for the same live child when safe, or invalidate the arm and preserve suppression

#### Scenario: Enabled child is not freshly confirmed

- **WHEN** exact-child enabled acknowledgement, exact registered Worker identity, authenticated channel, protocol compatibility, supported-model readiness, or a fresh challenge of the same Node Agent and Worker is missing
- **THEN** the Controller SHALL retain maintenance and scheduler exclusion

### Requirement: Rollback Selects Only the Exact Source Baseline

Rollback SHALL select only the immutable source baseline bound when the Controller transition generation was created.
It SHALL fence and stop the candidate registered-process set, verify purpose `rollback_to_source_baseline`, atomically restore the baseline pointer, and record `baseline_restored_stopped` before any baseline start.
The baseline SHALL use a new one-shot provisional start and the same Controller host-arm, pending-result consumption, exact-child enablement, incoming Worker gate, reserve-before-spawn registration, authenticated channel, Worker readiness, fresh Node Agent and Worker challenge, and terminal protocol.

#### Scenario: Exact baseline rollback succeeds

- **WHEN** the exact baseline, bootstrap, frozen identity, process fence, pointer switch, provisional child, Controller token, host arm, pending-result consumption, enabled-child acknowledgement, registered Worker readiness, authenticated channel, and fresh Node Agent and Worker proof all verify
- **THEN** the Controller MAY record terminal `rolled_back` and restore eligibility through the managed terminal protocol

#### Scenario: Another rollback target or reconstructed backup is offered

- **WHEN** rollback selects another source ref, another generation, copied backup bytes, prior loaded-service state, or generic resume
- **THEN** Orchard SHALL reject it

### Requirement: Uncertainty Remains Stopped and Unschedulable

Any uncertain activation, pointer, start, process, journal, bootstrap, identity, Controller, host-arm, pending-result, child-acknowledgement, recovery, or rollback result SHALL retain durable general launch suppression and Controller scheduler exclusion.
Only `succeeded` and fully accepted `rolled_back` are terminal outcomes.
All other failure and uncertainty states SHALL remain blocking recoverable phases in the same Controller transition generation.
No timeout, lifecycle-owner death, host reboot, launchd retry, heartbeat, or generic command SHALL convert uncertainty into eligibility.

#### Scenario: Host reboots during transition

- **WHEN** the host restarts with a nonterminal or uncertain managed journal
- **THEN** the stable bootstrap SHALL preserve general suppression
- **AND** the Node SHALL remain scheduler-excluded until exact managed terminal evidence commits
