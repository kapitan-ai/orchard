## ADDED Requirements

### Requirement: Compatible usage-status expansion

Request usage-status storage and readers SHALL preserve unclassified evidence according to `SPEC.md` §8.2 and deploy through the §13.2 expansion sequence before future classified writers activate.

#### Scenario: Unclassified rows span deployment phases

- **WHEN** historical, bridge-era, or in-flight Request rows have NULL output-usage status
- **THEN** readers SHALL treat the classification as not recorded
- **AND** SHALL NOT infer exact/lower-bound classification, row age, or deployment cutover from that NULL
- **AND** the expansion SHALL NOT default or backfill a classification

#### Scenario: Constraint validation follows committed expansion

- **WHEN** the usage-status column and CHECK are added to a populated Requests table
- **THEN** the CHECK SHALL enforce new inserts and updates without initial historical validation
- **AND** historical validation SHALL run in a separate migration transaction after expansion commits
- **AND** ordinary reads and writes SHALL remain compatible with the relation lock held by validation

#### Scenario: Worker updates do not activate classified writers

- **WHEN** the reader bridge is deployed alongside the Worker usage-update foundation
- **THEN** existing Completed-only accounting and current-write validation SHALL remain unchanged
- **AND** future classified writers SHALL wait until all Controllers and background readers support the persisted evidence vocabulary
