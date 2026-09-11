## MODIFIED Requirements

### Requirement: Production scheduling does not probe status inline
Production candidate construction and final dispatch revalidation SHALL use durable
observations and current Controller-owned facts without status-probing Runtime Endpoints on
the production scheduling path, apart from the single negotiated-reasoning exception below.
Database unavailability, incomplete reads, or absence of usable facts MUST NOT use stale
process memory or the unmanaged compatibility branch.
Initial allocation/legacy-claim acquisition and final acceptance-gated ADR 0013
revalidation SHALL remain mandatory.
The sole negotiated-reasoning exception is the bounded live selection wave that `SPEC.md`
§5.5 and §7.5.3a admit, which only an explicit `final_only` or `reasoning_structured`
Request opts into.
That wave SHALL remain selection evidence for that Request alone: it SHALL NOT become
trusted inventory or production capacity authority, SHALL NOT run for legacy traffic, and
SHALL NOT relax the durable-observation rule for ordinary candidate construction or final
dispatch revalidation.
`PrepareInference` SHALL remain the authoritative proof before model invocation, so a
placement that wave selects SHALL NOT authorize invocation on its own.
This requirement refines `SPEC.md` §4.6.2 and §5.9.

#### Scenario: Production snapshot is available
- **WHEN** fresh intersected production candidates exist
- **THEN** MultiNode filters and ranks them without a Runtime Endpoint status call

#### Scenario: Facts change after selection
- **WHEN** newer observation or Controller facts remove authority before execution
- **THEN** final revalidation refuses `ExecuteInference`
- **AND** pre-acceptance authority is released exactly once under existing retry/queue rules

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
