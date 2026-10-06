## ADDED Requirements

### Requirement: Request-local native effort has a bound rendered input contract

Orchard SHALL accept Chat `reasoning_effort` and Responses `reasoning.effort` only for supported low, medium and high values. Preparation SHALL bind the requested tier to an exact admitted artifact and reviewed template before tokenization or persistence. Native effort SHALL remain independent of public output projection and numeric reasoning budgets. Unsupported controls or routes SHALL reject rather than ignore or remap the request.

#### Scenario: Consecutive requests select different efforts

- **WHEN** a coding client selects medium and then high for the same admitted model
- **THEN** each request independently resolves its exact native mapping without another Catalog entry or effort-only model reload
- **AND** the authoritative renderer, token count, serialized identity and replay input preserve that request's selection

#### Scenario: Concurrent model-free preparation

- **WHEN** concurrent preparations select different supported tiers
- **THEN** no shared template argument state contaminates another request
- **AND** native capacity admission remains unchanged

#### Scenario: Omitted control

- **WHEN** a request omits effort
- **THEN** its legacy rendering, hashing and output behavior remain unchanged without a synthesized tier

#### Scenario: Unsupported exact tuple or tokenizer route

- **WHEN** the selected model/template or tokenizer route cannot apply the requested effort
- **THEN** preparation rejects before persistence and dispatch without substituting another value

#### Scenario: Helper proof mismatch

- **WHEN** helper metadata does not prove the exact canonical and native effort arguments
- **THEN** the Controller rejects the result as runtime incompatible before dispatch
