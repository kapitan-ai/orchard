## MODIFIED Requirements

### Requirement: Node Agent Owns Worker Processes

The Node Agent SHALL continue to own Worker Runtime lifecycle supervision, model loading, execution, cancellation, active allocation, capacity, diagnostics, and cleanup.
The Controller MUST communicate through the Node Agent Runtime Endpoint rather than directly managing runtime-provider processes.
Outside `managed_apple_silicon_macos_node`, the Node Agent SHALL continue to supervise Worker Runtime subprocesses directly under the portable provider contract.
Within the experimental managed profile, the Node Agent SHALL request Worker spawn, durable registration, termination, and exact exit proof through the stable privileged-helper protocol while retaining logical lifecycle ownership.
The helper SHALL act as the OS parent and process-custody authority, report exact registered-process exit to the Node Agent while it is live, and retain fail-closed custody when the Node Agent exits.

#### Scenario: Runtime provider crashes

- **WHEN** a Worker Runtime provider process crashes during local operation
- **THEN** direct supervision or the stable helper SHALL report the exact process exit under the active profile contract
- **AND** the Node Agent SHALL apply the portable worker supervision and failure contract when it remains live
- **AND** the Controller SHALL observe the result only through Runtime Endpoint or managed-transition semantics

#### Scenario: Managed Node Agent exits before its Worker during a nonterminal transition

- **WHEN** the managed Node Agent exits before a helper-registered Worker Provider while its managed transition is nonterminal
- **THEN** the stable helper SHALL retain custody, prevent new Worker initialization, close the generation channel, terminate the registered Worker, and preserve managed-transition suppression and exclusion

#### Scenario: Active managed Node Agent exits before its Worker

- **WHEN** the exact active-generation Node Agent exits after terminal acceptance and durable installation of its active-generation launch policy while a helper-registered Worker remains
- **THEN** the stable helper SHALL close the execution-epoch channel and terminate its registered Worker; the original live helper parent SHALL reap the child, while a restarted helper SHALL prove exit through liveness-gate EOF, exclusive lifetime-lock acquisition, and durable-registry reconciliation or remain suppressed
- **AND** Node Agent restart SHALL be permitted only through that exact active-generation launch policy
- **AND** the restarted Node Agent and Worker SHALL pass the ordinary health, identity, channel, and readiness gates before serving

#### Scenario: Terminal-active Node Agent exits before active-policy installation

- **WHEN** the managed Node Agent exits after Controller terminal acceptance but before durable active-generation launch-policy installation while a helper-registered Worker remains
- **THEN** the stable helper SHALL close the execution-epoch channel, prevent new Worker initialization, and terminate its registered Worker; the original live helper parent SHALL reap the child, while a restarted helper SHALL prove exit through liveness-gate EOF, exclusive lifetime-lock acquisition, and durable-registry reconciliation or remain suppressed
- **AND** general suppression SHALL remain preserved and restart SHALL be permitted only after stable-bootstrap reconciliation installs the exact terminal-result-bound policy
- **AND** the restarted Node Agent and Worker SHALL pass the ordinary identity, channel, health, and readiness gates before serving
