## MODIFIED Requirements

### Requirement: Source-dev BEAM Smoke Evidence Gate
Orchard SHALL gate Runtime Endpoint transport default promotions on durable two-Mac Source-dev BEAM smoke evidence.
The split-role source-dev BEAM default promotion executed after that evidence gate passed and is recorded in `docs/decisions/0001-runtime-endpoints-beam-first.md`.
Future Runtime Endpoint transport default promotions, such as packaged or release runtime transport, SHALL remain gated on the same accepted smoke evidence requirement.
The evidence SHALL be recorded durably in sanitized form in the accepting change package, decision record, or promotion pull request; standalone investigation or evidence documents SHALL NOT be committed to the repository.
The evidence SHALL include date, commit, sanitized hosts, commands, controller and node-agent BEAM node names, remote Runtime Endpoint RPC evidence, Console Nodes reachability for local and remote Node Agents, `GET /v1/models` returning `200`, and `POST /v1/chat/completions` completing through Console Playground or an equivalent API request.
The evidence SHALL NOT include cookie material, credentials, raw local evidence logs, local tool session identifiers, or machine-specific filesystem paths.
This refines the accepted smoke language in `SPEC.md` §1.2 and §7.5.

#### Scenario: Smoke evidence is complete
- **WHEN** a two-Mac Source-dev BEAM smoke run records all required evidence durably in the accepting change package, decision record, or promotion pull request
- **THEN** Orchard may consider a separate change that promotes a Runtime Endpoint transport default

#### Scenario: Smoke evidence is absent for a proposed promotion
- **WHEN** no durable two-Mac Source-dev BEAM smoke evidence exists for a proposed Runtime Endpoint transport default promotion
- **THEN** that promotion does not proceed and the current default remains unchanged
