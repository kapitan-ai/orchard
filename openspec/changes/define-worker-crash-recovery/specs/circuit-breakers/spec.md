## ADDED Requirements

### Requirement: Worker Crash-Loop Breakers Remain Policy-Separate

The `SPEC.md` §12.2 worker crash-loop placement breaker SHALL remain a separate policy and state machine from the §5.10 Node and model-load placement breakers.
It SHALL use separate identity, counters, incident evidence, recovery generation, state, persistence, reason code, inspection, and mutation paths.
The §5.10 thresholds, rolling windows, eligible failure classes, database decision-time semantics, suppression durations, automatic expiry, clear operations, and one-breaker-per-attempt attribution SHALL remain unchanged.
Shared low-level persistence or serialization helpers MAY be used only when the policy type remains explicit and one operation cannot mutate the other policy.
This requirement clarifies the boundary between `SPEC.md` §§5.10 and 12.2.

#### Scenario: Worker crash opens only the crash-loop breaker

- **WHEN** one exact worker recovery placement records five qualifying crashes in ten minutes
- **THEN** its §12.2 crash-loop breaker opens
- **AND** no §5.10 Node or model-load breaker contribution is manufactured

#### Scenario: Model load failures open the Controller placement breaker

- **WHEN** three eligible actual attempts produce `model_load_failure` for one §5.10 placement in ten minutes
- **THEN** the §5.10 model-load breaker follows its existing 15-minute suppression contract
- **AND** §12.2 crash history, restart streak, and recovery generation do not change unless a worker generation independently crashed

#### Scenario: One policy is cleared

- **WHEN** an Operator clears either a §5.10 breaker or a §12.2 crash-loop breaker
- **THEN** only the explicitly targeted policy changes
- **AND** the other policy's state, generation, history, and expiry remain unchanged

#### Scenario: Crash-loop time window elapses

- **WHEN** an open crash-loop breaker remains open after ten minutes
- **THEN** it does not inherit §5.10 automatic expiry
- **AND** only an effective explicit §12.2 recovery can close it

### Requirement: Worker Incidents Do Not Own Attempt Contributions

Only an actually run unsuccessful Request attempt with a durable eligible stable failure class SHALL contribute to a §5.10 breaker.
A worker crash incident, affected-request fan-out, restart decision, timer, stable reset, Runtime Endpoint observation, explicit recovery, retry decision, or declined restart MUST NOT create a §5.10 contribution.
Duplicate delivery of one attempt outcome SHALL remain idempotent, and one unsuccessful attempt SHALL continue to affect at most one §5.10 breaker.
This requirement preserves `SPEC.md` §§5.10 and 12.2.

#### Scenario: One crash affects several requests

- **WHEN** one worker crash terminalizes several actually running Request attempts
- **THEN** each actual attempt may contribute exactly once only if its own stable outcome is §5.10-eligible
- **AND** the single worker crash incident adds no extra contribution

#### Scenario: Restart timer fires

- **WHEN** a restart timer becomes eligible or is rejected as stale
- **THEN** neither §5.10 breaker receives a failure event
- **AND** no attempt identity is synthesized
