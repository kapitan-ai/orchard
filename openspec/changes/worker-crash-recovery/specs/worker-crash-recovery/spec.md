## ADDED Requirements

### Requirement: Placement-scoped qualifying worker crashes

The Node Agent SHALL enforce `SPEC.md` §12.2.1 per exact `(stable node_id, model_id, version)`, counting unexpected loss of an admitted loading or loaded worker at most once per incarnation. Current runtime/channel loss that makes the worker unusable SHALL qualify; intentional stop and non-crash load/admission errors MUST NOT qualify. Existing cumulative crash metrics SHALL remain separate from policy history.

#### Scenario: Loading worker dies with duplicate reports
- **WHEN** an admitted loading worker unexpectedly dies and both its DOWN and load failure arrive
- **THEN** that incarnation contributes one crash for its exact key
- **AND** another version or Node retains independent recovery state

#### Scenario: Load fails without worker death
- **WHEN** artifact validation, capacity admission, spawn before worker admission, or ordinary load returns an error without unexpected worker loss
- **THEN** no qualifying crash is added

#### Scenario: Intentional and stale events are excluded
- **WHEN** a prior stop intent explains termination or an event belongs to an old request generation, channel, worker, or load
- **THEN** it neither adds a crash nor terminates the current replacement

#### Scenario: Unload discovers an already dead worker
- **WHEN** unload discovers unexpected loss without a previously recorded intentional-stop decision
- **THEN** the loss is counted once before applying the unload/recovery semantics
- **AND** a subsequent unload does not retroactively reclassify that accepted loss as intentional

### Requirement: Bounded restart timing and fifth-crash trip

The Node SHALL apply the half-open monotonic window, separate capped delay index, ten-minute loaded stability reset, and fifth-crash-before-restart ordering in `SPEC.md` §12.2.1. An open breaker MUST NOT expire or probe automatically.

#### Scenario: Delay tail without an open breaker
- **WHEN** crashes occur at 0, 150, 300, 450, 601, 752, and 903 seconds with intervening eligible successful loads and no ten-minute stable interval
- **THEN** restart delays are 1, 2, 4, 8, 16, 30, and 30 seconds
- **AND** no restart starts before its due time

#### Scenario: Fifth crash opens before restart
- **WHEN** five qualifying crashes occur inside one ten-minute window
- **THEN** the fifth marks the placement failed/open before any new restart can be admitted
- **AND** no timer or ordinary load probes it after elapsed time

#### Scenario: Exact window and stability boundaries
- **WHEN** a crash is exactly 600 seconds old at a new crash observation
- **THEN** that old event is outside the rolling window
- **AND** a worker that has been continuously loaded for at least 600 seconds resets history/index before processing its next crash
- **AND** loading, backoff, and agent downtime do not establish loaded stability

### Requirement: Recovery residency ownership and failure handling

Automatic recovery SHALL restore residency only under explicit recovery ownership and the existing load pipeline, never replay a Request. It SHALL reserve exactly one model residency slot through backoff/restarting and release it only after cleanup resolves when recovery stops. Non-crash automatic restart failure SHALL retain history/index and stop as recovery-required, not count a crash or loop. This implements `SPEC.md` §12.2.1.

#### Scenario: No Request waiter remains
- **WHEN** an automatic restart successfully loads after the original Request has terminalized
- **THEN** the recovered worker remains resident under recovery ownership
- **AND** no inference Request or attempt is created or replayed

#### Scenario: Restart cannot obtain resources
- **WHEN** the authorized restart pipeline refuses resources without unexpected worker loss
- **THEN** automatic recovery stops as recovery-required without adding a crash
- **AND** it releases its residency slot only after resolved cleanup

#### Scenario: Open placement releases only resolved occupancy
- **WHEN** the fifth crash opens the breaker while runtime cleanup is unresolved
- **THEN** no replacement starts and unresolved occupancy is not advertised as free
- **AND** resolved cleanup releases the residency slot for other placements

### Requirement: Bounded durable checkpoint and scoped epoch recovery

The Node SHALL preserve recovery safety through the bounded Postgres checkpoint accessed via the authenticated Active Controller in `SPEC.md` §12.2.2. It SHALL checkpoint in-progress ownership before worker admission and checkpoint reset/clear before acknowledging it. Local files, direct Node database access, and lagging status observations MUST NOT substitute for this authority. Ordinary reset SHALL preserve known open state/history and fence affected work. State loss SHALL block only interrupted/history-bearing/uncertain placements, not clean or new keys; unavailable hydration SHALL defer admission rather than imply clean state.

#### Scenario: Fresh installation loads normally
- **WHEN** authoritative hydration finds no checkpoint for a new exact key
- **THEN** ordinary load may proceed after normal checks and successful write-ahead ownership checkpoint
- **AND** no operator startup re-arm is required

#### Scenario: Clean shutdown versus interrupted epoch
- **WHEN** a new manager/agent epoch hydrates a cleanly stopped key without crash history
- **THEN** it allows normal load admission
- **BUT WHEN** it hydrates open, recovery-required, history/index-bearing, or interrupted worker/load/recovery ownership
- **THEN** it retains open/recovery-required or requires explicit recovery for that affected key without rebasing old monotonic times
- **AND** committed loaded ownership alone is not a clean stop

#### Scenario: Empty-history recovery-required survives state loss
- **WHEN** a forced reload clears history, fails without a crash, checkpoints recovery-required with resolved ownership, and then loses its agent epoch
- **THEN** hydration retains recovery-required despite empty history and requires explicit recovery

#### Scenario: Crash before open checkpoint acknowledgement
- **WHEN** the fifth crash closes local admission but its open checkpoint cannot be acknowledged before agent loss
- **THEN** the previously committed in-progress ownership prevents implicit clean admission after restart
- **AND** explicit recovery is required even if that fifth crash timestamp was not committed

#### Scenario: Unavailable checkpoint authority
- **WHEN** hydration or a required pre-effect checkpoint cannot be acknowledged
- **THEN** the Node admits no new worker or recovery effect based on missing local state
- **AND** it retains existing §12.6 and occupancy rules without counting a checkpoint failure as a worker crash
- **AND** a pending automatic restart keeps its due time and one reserved slot while checkpointing is deferred, rather than becoming a non-crash restart failure
- **AND** it resumes only after the same unsuperseded checkpoint is confirmed

#### Scenario: Pending stability checkpoint overlaps a crash
- **WHEN** loaded stability has reached ten minutes but its reset checkpoint is unacknowledged when a crash arrives
- **THEN** the reset is applied before the crash and both are persisted in one current transition
- **AND** a late older acknowledgement cannot erase the new crash

#### Scenario: Old epoch cannot overwrite recovery
- **WHEN** an old owner sends a late checkpoint write after a new authenticated epoch has claimed resolved ownership
- **THEN** transactional epoch/revision comparison rejects the write
- **AND** it cannot erase the current state or authorize a load

### Requirement: Explicit operator recovery with generation-safe effects

Operator clear, non-forced unload/reload, and forced reload SHALL follow `SPEC.md` §12.2.2 through a dedicated authorized recovery operation. Successful absent unload SHALL clear state; ordinary reconciliation and force flags MUST NOT confer clear authority. Cleanup uncertainty SHALL fail closed, and epoch/revision/operation/worker fences SHALL prevent duplicate or stale destructive effects.

#### Scenario: Clear an open placement
- **WHEN** the authenticated operator clears the current exact open placement and cleanup/checkpointing resolve
- **THEN** history/index reset and it becomes armed absent without starting a load
- **AND** §5.10 breaker state is unchanged

#### Scenario: Prior-epoch cleanup requires affirmative proof
- **WHEN** explicit recovery targets a checkpoint with prior worker ownership
- **THEN** it resets only after no current worker/load remains and existing custody confirms prior-incarnation termination/nonexistence or that its host boot ended
- **AND** unknown custody returns unavailable without clearing, requiring operator cleanup and a fresh recovery command
- **AND** an empty new process map or reused PID alone is not proof

#### Scenario: Clear conflicts with a healthy live load
- **WHEN** clear targets a loaded worker or caller-owned load
- **THEN** it returns conflict without resetting or interrupting that worker/load

#### Scenario: Ordinary operator unload followed by load
- **WHEN** operator non-forced unload succeeds for a placement with no active executions, including one already absent/open
- **THEN** pending loads/timers are fenced and history/index clear durably
- **AND** a subsequent ordinary ensure may load it
- **BUT WHEN** active executions make non-forced unload busy
- **THEN** the operation does not clear state

#### Scenario: Forced reload is serialized
- **WHEN** operator forced reload resolves old runtime cleanup
- **THEN** it durably resets and admits one fresh load without intervening ordinary admission
- **AND** success is returned only once loaded
- **AND** non-crash load failure leaves recovery-required while actual worker loss follows crash policy

#### Scenario: Reconciliation and internal reset cannot clear
- **WHEN** reconciliation unloads/reloads, ordinary ensure sets force, or internal reset cancels pending work
- **THEN** known crash history/open state is not cleared
- **AND** interrupted recovery requires explicit operator recovery before ordinary admission

#### Scenario: Duplicate command after a later crash
- **WHEN** an earlier recovery command is delivered again after the placement revision changed
- **THEN** it returns only a retained matching result or a stale conflict
- **AND** it neither clears the new crash nor reloads or terminates a newer worker
