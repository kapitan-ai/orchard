## ADDED Requirements

### Requirement: Breaker facts are authoritative capacity inputs

Shared dispatch-capacity evaluation SHALL consume normalized durable breaker facts for the canonical Node and requested placement.
A consumer MUST NOT authorize work from a caller-supplied breaker default or infer breaker state from health, lifecycle, telemetry, or placement status.
Missing, malformed, mismatched, or unreadable required breaker facts SHALL produce an ineligible fail-closed decision without claiming a breaker transition.
This requirement refines `SPEC.md` §4.6.2, §5.5, and §5.10.

#### Scenario: Caller omits breaker authority

- **WHEN** a production consumer cannot assemble durable current breaker facts for the canonical candidate
- **THEN** shared evaluation returns no dispatch authority
- **AND** it does not substitute a permissive default

#### Scenario: Health and breaker disagree

- **WHEN** Node health is eligible but durable Node breaker state is actively suppressed
- **THEN** shared evaluation remains ineligible because the breaker gate fails
- **AND** it does not rewrite Node health
