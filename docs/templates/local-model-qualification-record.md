# Local Model Qualification Record

Copy this template to `docs/model-qualification-records/<record-id>.md`.
Follow [the standing policy](../model-qualification.md).
Delete instructional text that does not apply, but do not remove required fields.

## Record control

| Field | Value |
| --- | --- |
| Record ID | `<LMQ-YYYY-NNNN>` |
| Status | `draft`, `approved`, `hold_for_review`, `not_qualified`, `withdrawn`, or `superseded` |
| Evidence date | `<YYYY-MM-DD>` |
| Evidence author | `<name or accountable team>` |
| Qualification reviewer | `<name>` |
| Claim approver | `<Orchard maintainer with merge authority>` |
| Decision date | `<YYYY-MM-DD or pending>` |
| Supersedes | `<record ID or none>` |
| Superseded by | `<record ID or none>` |
| Related support claim | `<path or none>` |
| Pilot relationship | `<issue #118 or #196 reference, or none>` |

## Decision summary

- Proposed claim: `<one sentence naming capabilities and envelope>`
- Overall outcome: `<approved | hold_for_review | not_qualified | withdrawn | superseded>`
- Blocker type: `<none | model_defect | orchard_defect | environment_deviation | evidence_gap>`
- Blocking issue or decision: `<durable reference or none>`
- Resume condition: `<required rerun, decision, or none>`
- Decision rationale: `<concise evidence-backed rationale>`

## Exact qualification tuple

### Model and artifact

| Field | Exact value |
| --- | --- |
| Model namespace and checkpoint | `<value>` |
| Immutable checkpoint revision | `<value>` |
| Quantization | `<method, bit width, group size, and other material parameters>` |
| Artifact layout and format | `<value>` |
| Artifact size | `<bytes>` |
| Catalog Artifact Bundle SHA-256 | `<models.artifact_sha256>` |
| Manifest identity | `<path-free identifier or digest>` |
| Tokenizer identity | `<files, immutable revision, and digests>` |
| Chat template or renderer identity | `<files, implementation, revision, and digests>` |
| Processor or model-family adapter | `<identity and revision, or none>` |
| Manifest deviations | `<list or none>` |

Do not use the deprecated top-level manifest `sha256` as the Catalog Artifact Bundle digest.

### Runtime and Orchard

| Field | Exact value |
| --- | --- |
| Orchard revision or release | `<git SHA or immutable release>` |
| Worker Runtime provider | `<name and exact revision or version>` |
| Runtime dependencies | `<MLX, MLX-LM, tokenizer, parser, and other material versions>` |
| Acceleration implementation | `<value>` |
| Worker Runtime protocol | `<version>` |
| Runtime Endpoint transport and protocol | `<value>` |
| Controller tokenizer or renderer revision | `<value or fixed by Orchard revision>` |

### Environment and topology

| Field | Exact value |
| --- | --- |
| Topology | `<all-in-one or controller plus one to three worker Macs>` |
| Host role mapping | `<sanitized role and hardware mapping>` |
| Hardware | `<Mac model, chip, memory, device resources>` |
| Operating system | `<version and build>` |
| Database | `<version and material configuration>` |
| Runtime configuration | `<material values>` |
| Routing and admission configuration | `<material values>` |
| Context and generation limits | `<input, output, and context limits>` |
| Concurrency | `<requested and enforced values>` |
| Environment deviations | `<list or none>` |

### Applicable profiles and support gates

| Profile kind | Applicable profile | Current status | Acceptance evidence |
| --- | --- | --- | --- |
| Platform Profile | `<name>` | `<supported | target | experimental | other>` | `<SPEC.md, decision, issue, or accepted evidence>` |
| Distribution Profile | `<name or not applicable>` | `<supported | target | experimental | not applicable>` | `<reference or not applicable>` |
| Runtime-Provider Profile | `<name>` | `<supported | target | experimental | other>` | `<reference>` |
| Acceptance Profile | `<name>` | `<supported | target | experimental | other>` | `<reference>` |

If any applicable profile has not passed its support and acceptance gates, this record cannot authorize an active support claim.

## Serving mode and request budgets

Create one row for every measured cell.

| Cell ID | Serving mode | Cold-load time | Artifact verification included | Effective request deadline | Generation timeout | Queue-wait budget | Max cold-start budget | Deadline ceiling | Routing or residency policy | Pin, prewarm, or idle policy | Proxy timeout |
| --- | --- | ---: | --- | ---: | ---: | ---: | ---: | ---: | --- | --- | ---: |
| `<cell>` | `<cold_load_permitted | placement_preloaded>` | `<ms or not exercised>` | `<yes | no | unknown>` | `<ms>` | `<ms>` | `<ms>` | `<ms>` | `<ms>` | `<exact values>` | `<exact values>` | `<ms or none>` |

Preloaded evidence must not be summarized as a cold pass.

## Evidence ladder

| Boundary | Assertion | Acceptance criterion | Result | Cell or evidence reference | Defect or deviation |
| --- | --- | --- | --- | --- | --- |
| Artifact and import validation | `<assertion>` | `<predeclared criterion>` | `<pass | fail | blocked | not_tested>` | `<reference>` | `<reference or none>` |
| Runtime load | `<assertion>` | `<predeclared criterion>` | `<result>` | `<reference>` | `<reference or none>` |
| Meaningful generation | `<semantic assertion>` | `<predeclared meaning or exact-result criterion>` | `<result>` | `<reference>` | `<reference or none>` |
| Capability-specific conformance | `<capability assertion>` | `<predeclared criterion>` | `<result>` | `<reference>` | `<reference or none>` |
| Production qualification | `<operating-envelope assertion>` | `<predeclared criterion>` | `<result>` | `<reference>` | `<reference or none>` |

## Tested capability envelope

Use separate rows for endpoint and streaming modes.

| Capability | Endpoint or interface | Mode | Input and output limits | Sample count | Concurrency | Topology | Acceptance rule | Result |
| --- | --- | --- | --- | ---: | ---: | --- | --- | --- |
| `<capability>` | `<interface>` | `<streaming, non-streaming, or other>` | `<limits>` | `<count>` | `<count>` | `<topology>` | `<rule>` | `<pass | fail | blocked | not_tested>` |

## Capability classification for the proposed claim

### Supported

- `<capability, exact envelope, and evidence row, only when the overall outcome is approved>`

For `draft`, `hold_for_review`, `not_qualified`, `withdrawn`, or `superseded`, write `None. This record does not authorize supported capabilities.`
Passing cells remain visible in the evidence ladder and tested capability envelope.

### Unsupported

- `<capability and demonstrated limit, or none>`

### Unknown

- `<untested, insufficiently tested, or blocked capability>`

Reasoning remains unknown unless evaluated under an accepted reasoning contract owned by issue #190.

## Resource and reliability observations

| Measurement | Value | Scope and method |
| --- | ---: | --- |
| Peak Worker Runtime memory | `<value>` | `<cell and measurement method>` |
| Lowest available memory | `<value>` | `<cell and measurement method>` |
| Swap | `<value>` | `<cell and measurement method>` |
| Time to first token or delta | `<value>` | `<cell and sample summary>` |
| Output rate | `<value>` | `<cell and sample summary>` |
| End-to-end latency | `<value>` | `<cell and sample summary>` |
| Repeatability | `<value>` | `<cell and acceptance rule>` |
| Recovery | `<value>` | `<failure and recovery exercised>` |

## Evidence index and retention

| Evidence item | Sanitized summary | Durable reference | Protected package reference | Integrity digest |
| --- | --- | --- | --- | --- |
| `<ID>` | `<summary without raw prompts, responses, identifiers, logs, or paths>` | `<issue, PR, test, or decision>` | `<stable site-local reference or none>` | `<digest or none>` |

- Retention basis: `<active-claim lifetime plus twelve months after withdrawal or supersession | hold resolution plus twelve months | no-claim decision date plus twelve months>`
- Minimum retention end: `<pending lifecycle event or YYYY-MM-DD>`
- Evidence removal or exception: `<none or approved reason, date, and authority>`

## Requalification analysis

- Triggers already present: `<list or none>`
- Claim-specific future triggers: `<list>`
- Evidence proposed for reuse: `<rows or none>`
- Why reused evidence remains valid: `<bounded impact analysis or not applicable>`
- Assertions that must be rerun: `<list>`

## Review decision

The qualification reviewer confirms that tuple identity, acceptance criteria, evidence integrity, serving modes, capability boundaries, defect attribution, and exclusions were checked.

- Reviewer: `<name>`
- Review date: `<YYYY-MM-DD>`
- Findings: `<none or resolved references>`

The claim approver records one decision.

- Decision: `<approve | hold | reject | withdraw | supersede>`
- Approved claim envelope: `<exact scope or none>`
- Decision rationale: `<rationale>`
- Approver: `<name>`
- Approval date: `<YYYY-MM-DD or pending>`
- Merge reference: `<PR and commit, completed when effective>`

## Sanitization check

- [ ] No raw prompts or responses are committed.
- [ ] No credentials, tokens, tenant identifiers, user identifiers, logs, or machine paths are committed.
- [ ] Examples use synthetic or explicitly approved non-sensitive inputs.
- [ ] Evidence links are durable and access-controlled where required.
