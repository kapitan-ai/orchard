## ADDED Requirements

### Requirement: Selected effort preserves capture and replay boundaries

Inference capture, hashing, idempotency, preview, and replay implementations SHALL apply the `SPEC.md` section 9.3 hidden-reasoning rules identically for every valid selected effort. A selected tier is non-content policy evidence; an omitted tier MUST NOT be synthesized into the existing public-body hash or serializer domain.

#### Scenario: Final-only request selects a qualified tier

- **WHEN** a valid final-only Request selects a qualified effort tier and generates hidden reasoning
- **THEN** hidden reasoning remains ephemeral under every capture mode
- **AND** replay returns only the retained historical public projection without rerendering or selecting effort again
