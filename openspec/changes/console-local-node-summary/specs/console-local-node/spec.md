## ADDED Requirements

### Requirement: Installation-owned local association

The Controller SHALL use an explicit installation-selected registered Node identity store for local-machine display, without inferring co-location from addresses, names or inventory size and without creating another identity source.

#### Scenario: All-in-one environment generation
- **WHEN** new Controller configuration is generated for the all-in-one role
- **THEN** it names the local registered Node identity root
- **AND** existing environment files are not silently overwritten

#### Scenario: Missing or invalid local identity
- **WHEN** selected custody is absent, insecure, malformed or not registered
- **THEN** Console reports unknown local identity without creating identity files or revealing custody contents

### Requirement: Evidence-based local Node summary

Console SHALL require matching installed identity, trusted inventory target and current observed identity before displaying positive local Node evidence. Existing health and freshness rules remain authoritative and model-serving readiness remains separate.

#### Scenario: Healthy local Node without loaded models
- **WHEN** trusted identity matches and current evidence and heartbeat are fresh and healthy
- **THEN** Console displays “This machine’s Node is connected and healthy.”
- **AND** no loaded models does not contradict Node health or imply serving readiness

#### Scenario: Stale or unavailable evidence
- **WHEN** the heartbeat is stale or the current target cannot be observed
- **THEN** Console does not display the positive headline
- **AND** it distinguishes the last successful observation from the current failed attempt
- **AND** current model status remains unknown on probe failure

#### Scenario: Conflicting identity
- **WHEN** installation, trusted target or observed identity disagree
- **THEN** the local summary fails closed rather than attributing another Node's health to this machine
