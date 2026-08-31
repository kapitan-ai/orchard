## ADDED Requirements

### Requirement: Reasoning-aware retries preserve the existing retry contract

Automatic and operator retry implementations SHALL apply the reasoning identity, Output Commitment, attempt-evidence, and accounting rules in `SPEC.md` sections 3.7.1, 5.3, 5.8, and 7.3.4 through the existing bounded-retry contract.
Retry handling MUST NOT renegotiate the reasoning contract, treat hidden reasoning as selected public output, or infer a reasoning-token subset from total usage.

#### Scenario: No alternate endpoint proves the pinned contract

- **WHEN** an otherwise retry-eligible attempt has no different endpoint that proves the same negotiated reasoning contract
- **THEN** Orchard declines retry before dispatch
- **AND** it does not rerender, downgrade, or renegotiate the request

#### Scenario: The Controller cannot prove exact terminal usage

- **WHEN** the Controller synthesizes a terminal failure with only validated cumulative usage
- **THEN** retry evidence preserves the lower-bound status required by the apex contract
- **AND** it does not estimate a reasoning-token subset or collapse unknown to zero
