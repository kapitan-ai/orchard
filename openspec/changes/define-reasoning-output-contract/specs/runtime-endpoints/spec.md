## ADDED Requirements

### Requirement: Runtime Endpoint reasoning integration follows the apex contract

Runtime Endpoint implementations SHALL conform to the negotiated reasoning, Output Commitment, and mixed-version boundaries in `SPEC.md` sections 3.6, 5.8, 7.5.3a, and 13.1 without treating this OpenSpec delta as a duplicate wire contract.
The current Worker Runtime-to-Runtime Endpoint terminal event SHALL carry exact cumulative total output usage only; the Controller SHALL record that Worker-originated total with `output_usage_status = exact` in terminal Inference Attempt evidence.
Any exact reasoning-token subset SHALL remain Worker-internal evidence and MUST NOT cross the Runtime Endpoint event boundary until a separately accepted presence-aware contract defines its encoding.
An unavailable or unproven reasoning-token subset MUST remain unknown and MUST NOT be normalized to zero.

#### Scenario: Loaded-worker acceptance does not match

- **WHEN** the loaded Worker Runtime cannot prove the negotiated contract before model invocation
- **THEN** the Runtime Endpoint rejects execution through the pre-acceptance boundary
- **AND** no model output or usage event crosses the Runtime Endpoint boundary

#### Scenario: The Worker proves a reasoning-token subset

- **WHEN** the Worker Runtime proves exact total output usage and an exact reasoning-token subset
- **THEN** the current Runtime Endpoint terminal event carries only the exact cumulative total and the Controller records its status as exact in attempt evidence
- **AND** the reasoning-token subset remains inside the Worker Runtime
