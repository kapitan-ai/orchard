# Local Model Support Claim

Copy this template to `docs/model-support-claims/<claim-id>.md`.
Follow [the standing policy](../model-qualification.md).
An active claim requires an approved qualification record for the exact tuple and envelope below.

## Claim control

| Field | Value |
| --- | --- |
| Claim ID | `<LMSC-YYYY-NNNN>` |
| Status | `draft`, `active`, `withdrawn`, or `superseded` |
| Qualification record | `<relative path to approved record>` |
| Effective date | `<YYYY-MM-DD or pending>` |
| Claim approver | `<Orchard maintainer with merge authority>` |
| Supersedes | `<claim ID or none>` |
| Superseded by | `<claim ID or none>` |
| Withdrawal reference | `<issue or PR, or none>` |

## Scoped claim

`Orchard supports <exact model checkpoint and quantization> with <exact runtime> for <supported capabilities> within <tested hardware, topology, serving mode, and configuration envelope>.`

Do not replace this sentence with an unqualified statement that the model is supported.

## Exact qualified tuple

| Field | Qualified value |
| --- | --- |
| Model checkpoint and immutable revision | `<value>` |
| Quantization | `<value>` |
| Catalog Artifact Bundle SHA-256 | `<value>` |
| Tokenizer and renderer identity | `<value>` |
| Worker Runtime provider and revision | `<value>` |
| Runtime dependencies | `<value>` |
| Orchard revision or release | `<value>` |
| Worker Runtime and Runtime Endpoint protocols | `<value>` |
| Hardware and operating system | `<value>` |
| Topology | `<one to four Macs under SPEC.md section 1.1>` |
| Material configuration | `<value>` |

## Applicable supported profiles

| Profile kind | Supported profile | Acceptance evidence |
| --- | --- | --- |
| Platform Profile | `<name>` | `<SPEC.md, decision, issue, or accepted evidence>` |
| Distribution Profile | `<name or not applicable>` | `<reference or not applicable>` |
| Runtime-Provider Profile | `<name>` | `<reference>` |
| Acceptance Profile | `<name>` | `<reference>` |

An active claim cannot use a target-only, experimental, or otherwise unsupported profile.

## Supported capabilities

Every row must link to approved evidence in the qualification record.

| Capability | Interface and mode | Tested limits | Serving mode | Topology | Evidence |
| --- | --- | --- | --- | --- | --- |
| `<capability>` | `<endpoint, streaming or non-streaming>` | `<context, output, concurrency, samples, and other limits>` | `<cold_load_permitted | placement_preloaded>` | `<topology>` | `<qualification-record section>` |

## Operating envelope and limits

- Required hardware and memory: `<value>`
- Supported operating system: `<version and build envelope>`
- Required topology: `<value>`
- Runtime and dependency versions: `<value>`
- Effective request deadline: `<value>`
- Generation timeout: `<value>`
- Queue-wait budget: `<value>`
- Maximum cold-start budget: `<value>`
- Deployment deadline ceiling: `<value>`
- Routing and residency policy: `<value>`
- Residency, pinning, or prewarming requirement: `<value or none>`
- Proxy timeout requirement: `<value or none>`
- Context and output limits: `<value>`
- Concurrency limit: `<value>`
- Other required configuration: `<value>`

Preloaded evidence cannot support a cold-service claim.
If `placement_preloaded` appears above, state the residency requirement as a visible limit.

## Unsupported capabilities

List only capabilities that evidence demonstrated as unsupported for this exact tuple and envelope.

- `<capability, demonstrated limit, and evidence>`

## Unknown capabilities

List every material capability that was untested, insufficiently tested, or blocked.

- `<capability and reason>`

Reasoning behavior remains unknown unless it was qualified under an accepted contract owned by issue #190.

## Exclusions

- `<hardware, operating system, topology, endpoint, feature, context, concurrency, or workload excluded from the claim>`
- `<known defect or deviation and its effect>`

Catalog activation, Tenant publication, and runtime loadedness are not support evidence and are not part of this claim.

## Evidence

- Qualification record: `<relative link>`
- Durable issue or pull-request evidence: `<links>`
- Protected evidence package reference: `<stable identifier>`
- Protected evidence package digest: `<digest>`
- Evidence retention basis: `active for the complete claim lifetime, then at least twelve months after withdrawal or supersession`
- Minimum retention end: `<pending withdrawal or supersession, then lifecycle date plus twelve months>`

Do not include raw prompts, responses, credentials, logs, identifiers, or machine paths.

## Requalification conditions

This claim must be withdrawn or superseded before continued publication when any applicable trigger in the standing policy occurs.

Claim-specific triggers:

- `<trigger>`
- `<trigger>`

Issue closure, green CI, or a version bump does not transfer evidence automatically.

## Approval and lifecycle

- Qualification outcome: `approved`
- Qualification reviewer: `<name and date>`
- Claim approver: `<name and date>`
- Effective merge: `<PR and commit>`
- Withdrawal or supersession authority: `<Orchard maintainer with merge authority>`
- Current lifecycle note: `<active scope, withdrawal reason, or replacement>`

## Publication check

- [ ] The qualification record is approved for this exact tuple.
- [ ] Every supported capability is inside the approved envelope.
- [ ] Unknown and unsupported capabilities are visible.
- [ ] Serving mode, deadlines, routing values, and residency limits are explicit.
- [ ] Every applicable Platform, Distribution, Runtime-Provider, and Acceptance Profile is already supported and linked to acceptance evidence.
- [ ] The claim does not select or announce a pilot default owned by issue #118 or issue #196.
- [ ] The claim does not define reasoning behavior owned by issue #190.
- [ ] No product enforcement or state transition is implied.
- [ ] No sensitive or transient evidence is committed.
