## MODIFIED Requirements

### Requirement: Production scheduling does not probe status inline
Production candidate construction and final dispatch revalidation SHALL use durable
observations and current Controller-owned facts without status-probing Runtime Endpoints on
the production scheduling path, apart from the single negotiated-reasoning exception below.
Database unavailability, incomplete reads, or absence of usable facts MUST NOT use stale
process memory or the unmanaged compatibility branch.
Initial allocation/legacy-claim acquisition and final acceptance-gated ADR 0013
revalidation SHALL remain mandatory.
Worker recovery admission SHALL decide from the durable observation and its placement
projections on that path.
An omitted placement in a valid projection below its bound may be treated as cold, so a fresh
authenticated recovery epoch SHALL admit it, while a loaded placement without exact
current-epoch evidence SHALL remain refused. Absence is cold evidence only because the Node
reports its recovery epoch after hydrating every stored checkpoint that is not proven clean; an
observation without an epoch SHALL NOT establish cold absence.
Only the bounded unmanaged-compatibility wave MAY resolve a cold placement with a targeted
read-only recovery query, and a transport that cannot answer that query SHALL fall back to
epoch-only evidence only when a valid placement projection is below its bound.
At the bound, an omitted key SHALL require exact current-epoch inspection evidence on that
wave; unsupported or unavailable inspection SHALL remain fail-closed. Production scheduling
SHALL NOT perform an inline query to resolve that omission.
The sole negotiated-reasoning exception is the bounded live selection wave that `SPEC.md`
§5.5 and §7.5.3a admit, which only an explicit `final_only` or `reasoning_structured`
Request opts into.
That wave SHALL remain selection evidence for that Request alone: it SHALL NOT become
trusted inventory or production capacity authority, SHALL NOT run for legacy traffic, and
SHALL NOT relax the durable-observation rule for ordinary candidate construction or final
dispatch revalidation.
`PrepareInference` SHALL remain the authoritative proof before model invocation, so a
placement that wave selects SHALL NOT authorize invocation on its own.
This requirement refines `SPEC.md` §4.6.2, §5.9, and §12.2.3.

#### Scenario: Production snapshot is available
- **WHEN** fresh intersected production candidates exist
- **THEN** MultiNode filters and ranks them without a Runtime Endpoint status call

#### Scenario: Facts change after selection
- **WHEN** newer observation or Controller facts remove authority before execution
- **THEN** final revalidation refuses `ExecuteInference`
- **AND** pre-acceptance authority is released exactly once under existing retry/queue rules

#### Scenario: Cold production candidate is admitted without a recovery query
- **WHEN** a production candidate reports a fresh recovery epoch and no loaded placement for
  the requested model in a valid projection below its bound
- **THEN** recovery admission accepts it with no Runtime Endpoint status or inspection call
- **AND** a loaded placement lacking exact current-epoch evidence is still refused without a
  reprobe

#### Scenario: Restarted Node cannot present an unhydrated key as cold
- **WHEN** a Node Agent restarts while a stored checkpoint for the requested key is open or
  recovery-required
- **THEN** its observation carries no recovery epoch until that key is hydrated, and then
  reports the key's blocked state
- **AND** recovery admission rejects the candidate before ranking in both phases

#### Scenario: Uninspectable transport does not imply unrecovered state
- **WHEN** the bounded unmanaged-compatibility wave reaches a transport that cannot answer a
  recovery query and its valid placement projection is below the bound
- **THEN** admission uses the authenticated epoch alone
- **AND** the candidate is not refused for missing recovery evidence

#### Scenario: Exact inspection resolves capped unmanaged evidence
- **WHEN** the bounded unmanaged-compatibility wave omits a requested key from an otherwise
  valid placement projection at its bound
- **THEN** a targeted inspection may establish eligibility only for the exact Node/model/version
  with hydrated current-epoch evidence
- **AND** wrong-key, stale-epoch, blocked, unavailable or unsupported inspection cannot admit it
- **AND** the production durable-snapshot path remains refused without an inline query

#### Scenario: Negotiated reasoning request runs its bounded live wave
- **WHEN** an explicit negotiated reasoning Request reaches scheduling
- **THEN** its bounded `SPEC.md` §7.5.3a wave may observe loaded placements live for that
  Request's selection only
- **AND** ordinary candidate construction and final dispatch revalidation still use durable
  observations and Controller-owned facts
- **AND** `PrepareInference` still proves the exact tuple before model invocation

#### Scenario: Legacy request is unaffected by the reasoning exception
- **WHEN** an omitted legacy Request reaches scheduling
- **THEN** Orchard runs no reasoning wave for it
- **AND** it performs no inline status probe outside the explicitly unmanaged compatibility
  branch
