## MODIFIED Requirements

### Requirement: Developer Portal Is Isolated From Every Platform Authority

Orchard SHALL expose a Developer Portal browser surface at `/portal/:organization_slug` that is distinct from Orchard Console.
The portal SHALL NOT render operator Console chrome, other Organizations, nodes, or cluster administration.
A Portal User SHALL authorize only the Developer Portal for that Portal User's Organization.
A Portal User session SHALL NOT authorize Public Inference, Operator API, Admin API, or Console access.
This refines `SPEC.md` §2.3, §7.1, and §7.4a.

#### Scenario: Portal User cannot authorize Console

- **WHEN** a caller presents only a valid Portal User session
- **THEN** requests to Console SHALL NOT be authorized by that session
- **AND** the portal HTML SHALL NOT include Console navigation or operator chrome

#### Scenario: Portal User cannot authorize Operator or Admin APIs

- **WHEN** a caller presents only a valid Portal User session to the Operator API or Admin API
- **THEN** Orchard SHALL fail closed
- **AND** Orchard SHALL NOT treat the session as Operator, Admin, Tenant Admin, or Bearer authority

#### Scenario: Portal User session is not Public Inference authority

- **WHEN** a caller presents a Portal User session without an `orchard_sk_*` Bearer credential to Public Inference
- **THEN** Public Inference authentication SHALL fail
- **AND** Orchard SHALL NOT treat `portal_user_id` as a Public Inference principal
