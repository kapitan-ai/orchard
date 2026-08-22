## ADDED Requirements

### Requirement: Effective request deadlines have a deployment ceiling

The Controller SHALL read a deployment-owned maximum effective request deadline
from `ORCHARD_MAX_REQUEST_DEADLINE_MS`. The ceiling SHALL bound the complete
effective deadline, including generation, queue wait, and cold start. Its
provisional default SHALL be 360000 milliseconds.

#### Scenario: Cold-path deadline is bounded

- **GIVEN** an `allow_cold_load` policy whose generation, queue-wait, and cold-start budgets sum above the configured ceiling
- **WHEN** the policy is saved
- **THEN** the save SHALL be rejected with the computed effective deadline and ceiling in the validation error

#### Scenario: Loaded-only deadline ignores unused cold budgets

- **GIVEN** a `required_loaded` or `prefer_loaded` policy
- **AND** its generation budget is at or below the ceiling
- **WHEN** the policy is saved
- **THEN** unused queue-wait and cold-start values SHALL NOT cause rejection

### Requirement: Configuration and request resolution fail closed

The Controller SHALL reject incoherent configuration when the configured
generation timeout exceeds the deployment ceiling. When a previously saved
policy resolves above a newly lowered ceiling, request resolution SHALL cap
the effective deadline and emit an observable warning naming both values.

#### Scenario: Proxy timeout exceeds the deployment ceiling

- **GIVEN** a reverse proxy fronts the Controller
- **THEN** its response timeout SHALL exceed `ORCHARD_MAX_REQUEST_DEADLINE_MS`
- **AND** the deployment documentation SHALL state that a proxy timeout at or below the ceiling makes the cold-start budget fiction
