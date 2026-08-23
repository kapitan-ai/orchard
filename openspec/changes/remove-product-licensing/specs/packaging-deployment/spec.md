## MODIFIED Requirements

### Requirement: Distribution Artifacts Remain Generic

Orchard distribution artifacts SHALL remain generic across app, DMG, PKG, and future release channels, with database configuration, TLS material, and deployment secrets provided out of band.

#### Scenario: Deployment secrets stay separate

- **WHEN** Orchard is distributed through an app-primary DMG, signed PKG, or future download channel
- **THEN** the artifact does not embed customer identifiers, database DSNs, production TLS material, or deployment secrets
- **AND** the artifact does not require product-license activation
