## ADDED Requirements

### Requirement: Request-local native effort has a bound rendered input contract

Orchard SHALL accept Chat `reasoning_effort` and Responses `reasoning.effort` only for the selected model/template registration's supported bounded public identifiers; the vocabulary SHALL be extensible without a universal fixed set. Preparation SHALL bind the requested tier to an exact admitted artifact and reviewed template before tokenization or persistence. Native effort SHALL remain independent of public output projection and numeric reasoning budgets. Unsupported controls or routes SHALL reject rather than ignore or remap the request.

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

### Requirement: Authorized model discovery exposes exact effort capabilities

Orchard SHALL expose model-specific supported public values, explicit native mappings, informational template default and omission behavior in the additive `orchard_reasoning_effort` object on already authorized active model-list entries. Discovery SHALL share admission's exact profile lookup, advertise no support for missing evidence or unavailable routes, and run no inference, tool preflight or weight reads. The registered vocabulary SHALL support nonempty subsets and additional identifiers without silent fallback or a universal fixed enum. Default metadata SHALL NOT synthesize omitted request controls.

#### Scenario: Registered model and compatibility alias

- **WHEN** an authorized client lists the exact registered Qwen model
- **THEN** it discovers low, medium, xhigh and the explicit high-to-xhigh compatibility mapping plus informational xhigh default
- **AND** it may independently select each supported value on both inference endpoints while output display and token caps remain separate

#### Scenario: Unsupported value and unknown identity

- **WHEN** a model lacks an exact registration or cannot apply a selected value
- **THEN** discovery advertises no fabricated capability and authoritative preparation rejects before persistence and dispatch without fallback

#### Scenario: Tenant visibility

- **WHEN** the selected model is inactive, revoked, disabled, ungranted or visible only to another tenant
- **THEN** its identity and effort capabilities are omitted from model discovery
