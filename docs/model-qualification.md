# Local Model Qualification and Support Claims

This document defines Orchard's standing manual policy for qualifying a local model and publishing a scoped support claim.
It implements the governance decision in [ADR 0028](decisions/0028-mandatory-manual-model-qualification.md).
It does not change Orchard product behavior, persistence, APIs, scheduling, runtime protocols, or Console surfaces.

## Authority and effective date

This policy is mandatory for an Orchard support claim that names a local model.
It becomes effective when the pull request that introduces ADR 0028 and this policy merges.
The policy is enforced through repository review and merge authority, not by Orchard product state.

An active support claim requires an approved qualification record for the exact tuple and tested envelope it describes.
Catalog activation, Tenant publication, a loaded placement, a successful HTTP response, or plausible text cannot replace that record.

## Keep the boundaries separate

| Boundary | What it proves | What it does not prove |
| --- | --- | --- |
| Catalog state | The model is `registered`, `active`, `deprecated`, or `retired` under `SPEC.md` section 6.2. | Tenant access, runtime readiness, qualification, or support. |
| Tenant publication | An authorized Tenant may list and select the model under `SPEC.md` sections 6.6 and 7.2.3. | A loaded placement, conformance, or support. |
| Runtime availability | An eligible Model Placement is loaded and ready for the observed request path. | Semantic correctness, cold service, another topology, or support. |
| Qualification | Reviewed evidence applies to one exact qualification tuple and tested capability envelope. | Capabilities, configurations, or environments outside that envelope. |
| Support claim | Orchard publishes a scoped summary of approved qualification evidence, limits, and exclusions. | Product state, permanent compatibility, or untested capability support. |

Issue #118 and issue #196 retain ownership of pilot model selection, pilot evidence, and any pilot default.
Issue #190 retains ownership of reasoning controls, parsing, events, API projection, and persistence.
This policy supplies record and claim vocabulary only.

### Catalog tool-capability admission is not qualification

A Model Hub-generated `tool_capability_evidence.json` sidecar records only the exact source repository and revision, downloaded tokenizer/template artifact digests, parser identity, and bounded definition/history rendering result used to admit `tool_calling` to the Catalog. The importer retains the sidecar in the Artifact Bundle and copies it to the immutable Catalog model record without changing the closed worker manifest schema. It is not a manual qualification record. `runtime_qualification: not_established` remains explicit even when the Catalog capability is declared.

Positive sidecar claims, including offline-authored claims, must match the bundled config/template digests and parser declaration and pass a fresh static preflight during bundle parsing. An unverifiable positive claim rejects the bundle; it does not establish admission or qualification.

A declared Catalog capability permits the existing request-time capability gate; it does not support a claim, qualify a runtime, authorize server-side tool execution, or prove a particular model family. Missing evidence, an unknown tuple, or conflicting evidence remains chat-only. Base-model references are provenance only and cannot substitute for exact tuple evidence.

If a capability repair is needed, use the Console Model Hub repair action to enter a distinct explicit Catalog version for the same immutable source revision. Do not edit a Catalog row or its stored Artifact Bundle. The new Artifact Bundle requires its own qualification analysis; no prior support claim transfers automatically.

## Vocabulary and outcome model

Qualification results are capability-scoped, not ordered levels.
A higher-sounding label must not imply that unrelated capabilities passed.

Each evidence row uses one of these results:

- `pass`: the stated assertion passed within the recorded envelope.
- `fail`: the assertion was exercised and did not meet its acceptance criterion.
- `blocked`: the assertion could not reach a valid conclusion because a named defect or evidence gap blocked it.
- `not_tested`: the assertion was outside the run.

Each qualification record has one overall outcome:

- `approved`: all mandatory assertions for the proposed claim passed, and no unresolved blocker invalidates the claim.
- `hold_for_review`: evidence is usable, but a named model defect, Orchard defect, environment deviation, or evidence gap prevents approval or honest rejection.
- `not_qualified`: the exact tuple failed a mandatory assertion for the proposed claim and no review hold is appropriate.
- `withdrawn`: an earlier decision is no longer safe to rely on.
- `superseded`: a newer approved record replaces the record for claim purposes.

`hold_for_review` is not approval.
It must name the blocker type, blocking issue or decision record, affected assertions, and the event that permits review to resume.
Closing the blocker does not turn the hold into a pass.
The affected assertions must be rerun or an approver must accept a documented, bounded evidence-reuse analysis.

## Exact qualification tuple

Every record identifies one exact model, runtime, artifact, and environment tuple.
At minimum, record:

### Model and artifact identity

- model namespace and checkpoint name;
- immutable checkpoint revision;
- quantization method and parameters;
- authoritative Catalog Artifact Bundle digest from `models.artifact_sha256`;
- artifact size and artifact layout;
- tokenizer files, revisions, and digests;
- chat template, prompt renderer, processor, or equivalent model-family adapter revisions and digests; and
- manifest identity plus any accepted deviations from the manifest.

The deprecated top-level manifest `sha256` is not the Artifact Bundle digest.
Use the Catalog digest defined by `SPEC.md` section 6.4.

### Runtime and Orchard identity

- Worker Runtime provider and exact revision or package version;
- acceleration implementation and relevant runtime dependency versions;
- Worker Runtime protocol version;
- Runtime Endpoint transport and protocol version;
- exact Orchard revision or release identifier; and
- tokenizer and renderer implementation revision when it is not already fixed by the Orchard revision.

### Environment identity

- host role and topology;
- hardware model, chip, memory, and relevant device resources;
- operating system version and build;
- database version when it can affect the exercised path;
- material runtime, routing, admission, concurrency, context, generation, and memory settings; and
- deviations from the supported or documented environment.

Examples must remain within the `SPEC.md` section 1.1 limit of one to four Macs.
Model size and tested hardware remain part of the envelope even when the model fits other systems in theory.

## Required evidence ladder

A record evaluates the following boundaries separately.
A later pass does not erase an earlier failure or replace its evidence.

1. **Artifact and import validation** verifies source identity, bundle structure, secure import, final stored Artifact Bundle digest, tokenizer and template presence, and manifest acceptance.
2. **Runtime load** verifies the real Node Agent and Worker Runtime path can acquire or find, verify, load, report ready, and unload the exact artifact.
3. **Meaningful generation** verifies the real request path returns non-empty, coherent output that satisfies a bounded, predeclared assertion.
4. **Capability-specific semantic and API conformance** verifies each claimed capability across the exact public API modes and semantics named by the claim.
5. **Production qualification** verifies the proposed operating envelope, including deadlines, serving mode, topology, repetition, concurrency, context, resource headroom, failure handling, and recovery requirements that apply to the claim.

At least one meaningful-generation assertion must check meaning or an exact expected result.
"Returned HTTP 200" and "looked plausible" are not semantic acceptance criteria.

## Capability envelope

The record must enumerate capabilities rather than copy manifest declarations as proof.
Typical cells include:

- `/v1/responses` non-streaming;
- `/v1/responses` streaming;
- `/v1/chat/completions` non-streaming;
- `/v1/chat/completions` streaming;
- request cancellation and disconnect behavior;
- tool-calling passthrough;
- JSON or structured-output behavior;
- safe tokenization and template compatibility;
- context-length boundaries;
- concurrency and repeated-request behavior; and
- recovery after load, worker, Node, or transport failure.

Record the prompt class, input and output token limits, context window exercised, sample count, concurrency, topology, and acceptance rule for each cell.
Reasoning behavior remains `unknown` unless evidence is evaluated under the contract that issue #190 establishes. Qualified reasoning-effort selection is a separate capability cell: a record that names canonical `low`, `medium`, or `high` must identify the exact artifact/template renderer mapping and the exact negotiated tuple for each tier.

Static renderer acceptance proves only that exact mapping. Runtime conformance separately proves fresh complete-tuple advertisement and loaded-worker acceptance before invocation; semantic qualification separately proves predeclared tier assertions and final-only separation; and an approved scoped support claim separately decides what may be represented as offered. None of those later boundaries is implied by the prior one, and manual qualification never replaces Runtime Endpoint dispatch proof.

Because a selected tier is valid only with `generation_policy = enabled`, semantic qualification must also prove that the tier yields valid non-empty reasoning content across the envelope it claims, including its shortest and simplest prompt classes. A tier whose renderer can legitimately return no reasoning for a claimed prompt class fails the `SPEC.md` §7.5.3a enabled-conformance rule and is recorded as `unsupported` for that exact tuple rather than being offered and then surfacing as a terminal conformance failure.

Every claim classifies a capability as:

- `supported`: approved evidence covers the capability and the claim states its envelope;
- `unsupported`: evidence demonstrates the exact tuple cannot satisfy the stated capability or limit; or
- `unknown`: the capability was not tested, evidence was insufficient, or a blocker prevents a conclusion.

Untested capabilities are `unknown`, never implied by a manifest declaration or plausible response.

## Applicable profile gates

Model qualification cannot promote a Platform Profile, Distribution Profile, Runtime-Provider Profile, or Acceptance Profile from target status to supported status.
Every record identifies the profiles that apply to its hardware, host roles, runtime provider, distribution, and topology, together with their current support status and acceptance evidence.

An active local-model support claim may use only profiles whose applicable support and acceptance gates have already passed under `SPEC.md` sections 1.1, 1.4, and 1.5.
For example, portable compilation or a successful model run cannot declare the Linux Controller profile supported before Milestone 8 acceptance.

Evidence gathered on a target-only, experimental, or otherwise unsupported profile may remain useful in a draft or `hold_for_review` record.
It cannot authorize an active support claim until the profile gates pass and the affected model assertions are reviewed for continued applicability.

## Serving mode, deadlines, and residency

Every measured result states exactly one serving mode:

- `cold_load_permitted`: the measurement began without a loaded placement and allowed Orchard to perform the cold path; or
- `placement_preloaded`: the measurement depended on a placement made resident before the request.

Preloaded evidence cannot be reported as a cold pass.
A support claim that depends on preloading must state the residency requirement as an operating limit.

For every latency, throughput, load, repeatability, or conformance result, record the effective values that bounded the request:

- cold-load duration and whether artifact verification was included;
- effective request deadline;
- generation timeout;
- queue-wait budget;
- maximum cold-start budget;
- deployment request-deadline ceiling;
- routing policy and residency preference;
- pin, prewarm, idle-expiry, or reconciliation settings; and
- proxy timeout when the public path passed through a proxy.

The request-deadline and proxy relationship must follow [ADR 0022](decisions/0022-request-deadline-ceiling-and-proxy-timeouts.md).

## Records and evidence locations

Use [the qualification-record template](templates/local-model-qualification-record.md) for a new record.
Commit approved, held, not-qualified, withdrawn, and superseded records under `docs/model-qualification-records/<record-id>.md`.

Use [the support-claim template](templates/local-model-support-claim.md) for a published claim.
Commit claims under `docs/model-support-claims/<claim-id>.md`.

The repository record contains the sanitized decision evidence needed for review:

- exact tuple and tested envelope;
- predeclared assertions and summarized results;
- aggregate measurements;
- defect and deviation references;
- approver decision;
- evidence-package location identifier and integrity digest; and
- links to durable issues, pull requests, decisions, or accepted test artifacts.

Keep raw prompts, responses, credentials, tokens, logs, machine paths, tenant identifiers, user identifiers, and transient investigation traces out of the repository.
Use synthetic or explicitly approved non-sensitive inputs.
Store any protected supporting package in an access-controlled, site-local evidence store and identify it by a stable reference plus digest.

The durable record and support claim remain in Git history indefinitely.
Retain a supporting evidence package for an active claim throughout the claim's lifetime and for at least twelve months after withdrawal or supersession.
Retain evidence for a `hold_for_review` record until the blocker reaches a final qualification decision and for at least twelve months after that decision.
Retain evidence for an `approved` record that has no active claim for at least twelve months after approval, or under the active-claim rule if a claim is later published.
Retain evidence for a `not_qualified`, `withdrawn`, or `superseded` record that has no active claim for at least twelve months after its decision date.
Security, incident-response, legal, or data-governance obligations may require longer retention or earlier removal of sensitive material.
When evidence must be removed, retain the record, package digest, removal date, reason, and approving authority.

## Review and authority

The evidence author prepares the qualification record and must not silently change acceptance criteria after seeing results.
A qualification reviewer checks tuple identity, assertions, evidence integrity, boundary separation, defect attribution, and claim scope.
An Orchard maintainer with repository merge authority is the claim approver.

When another qualified maintainer is available, the evidence author must not be the sole reviewer and approver.
If a sole-maintainer exception is necessary, the record must disclose the combined roles and explain the compensating review evidence.

Approval, withdrawal, and supersession take effect through a merged repository change.
Any qualification reviewer or Orchard maintainer may place a draft record on `hold_for_review` when evidence is ambiguous or a named defect blocks classification.
Only an Orchard maintainer with merge authority may approve a claim, remove a hold, withdraw an active claim, or supersede an approved record.

The approving pull request must verify that:

- the qualification record is approved for the exact claim envelope;
- the support claim does not broaden supported capabilities, environment, or topology;
- every applicable Platform, Distribution, Runtime-Provider, and Acceptance Profile is already supported and linked to its acceptance evidence;
- exclusions and unknown capabilities are visible;
- issue #118 and issue #196 remain the authority for any pilot selection or default; and
- no product enforcement is implied.

## Withdrawal and supersession

Withdraw an active claim when evidence is invalid, a material defect makes the claim unsafe or false, the evidence package is unavailable without an accepted replacement, or a requalification trigger invalidates the supported envelope.
Withdrawal must state the effective date, reason, affected claims, and owner for follow-up.
When a qualification record stops being approved, every linked active claim must be withdrawn or superseded in the same merged change.

Supersede a record or claim when a newer approved exact tuple or tested envelope replaces it.
The replacement must link back to the superseded artifact, and the older artifact must link forward when edited in the same change.
Supersession never rewrites historical evidence.

Reducing a claim's envelope may use withdrawal plus a narrower replacement claim.
Expanding a claim requires approved evidence for every added capability or limit.

## Requalification triggers

Requalification is required before a claim continues to apply when any of these changes can affect the tested envelope:

- checkpoint revision, artifact bytes, Artifact Bundle digest, quantization, adapter, or artifact layout;
- tokenizer, chat template, prompt renderer, processor, parser, qualified reasoning-effort mapping, or tool marker behavior;
- Worker Runtime provider, runtime dependencies, acceleration implementation, or Worker Runtime protocol;
- Orchard revision, public API contract, Runtime Endpoint transport, or internal worker protocol;
- routing, residency, pinning, prewarming, queue, concurrency, context, generation, memory, or failure-handling configuration;
- effective request deadline, request-admission budget, proxy timeout, maximum cold-start budget, or measured cold-start cost;
- hardware, memory, operating system, database version, host roles, or topology;
- a material model, Orchard, security, integrity, or correctness defect;
- closure or material change of an issue that caused `hold_for_review`; or
- loss, corruption, or unverifiability of required evidence.

Every trigger creates a new exact-tuple record or a new revision that names the prior record.
An impact analysis may bound reruns to affected assertions only when it explains why every reused result remains valid for the new tuple.
The approver must accept that analysis explicitly.
Issue closure, a green CI run, or a version bump alone cannot carry old evidence forward.

## Worked walkthroughs

These walkthroughs demonstrate how to use the templates.
They are not qualification records, support claims, pilot defaults, or product acceptance evidence.

### Scoped approved claim

A synthetic exact tuple on one Apple Silicon Mac passes Artifact Bundle verification, real MLX load and unload, meaningful generation, and both streaming and non-streaming `/v1/responses` cells.
It also passes ten sequential requests at concurrency one with `cold_load_permitted`, a recorded 28-second cold load, an effective 120-second request deadline, and the exact routing values in force.
Tool calling, `/v1/chat/completions`, long context, reasoning, multi-node behavior, and concurrency above one are `unknown`.

The qualification outcome may be `approved` for `/v1/responses` at concurrency one on that exact hardware and configuration.
The support claim must list only those supported cells and must display every unknown and operating limit.
It cannot say that the model is generally supported.

### Eight-bit cold-start hold

A sanitized historical run of an eight-bit tuple on one Apple Silicon Mac passed import, real runtime load, meaningful generation, warm public APIs, and repeated streaming while `placement_preloaded`.
Its cold public request failed before a worker spawned because the effective request deadline expired.
The runtime evidence showed that the model could load and generate, so classifying the tuple as model-incompatible would have been false.

The correct outcome at the time of the run was `hold_for_review` with `blocker_type: orchard_defect`, issue #252 as the blocker, and the cold-service assertions marked `blocked` or `fail` according to their predeclared acceptance criteria.
The warm results remain valid only as preloaded evidence and must state the residency requirement.
Issue #253 remains relevant to cold-start cost attribution.

Issue #252 is now closed, but that closure does not approve the tuple.
It triggers requalification of the cold boundary on an exact current Orchard revision and requires a new approval decision before any support claim.

## Product-change boundary

This policy adds no Catalog or Placement state and no qualification persistence inside Orchard.
It adds no manifest field, API projection, scheduler or publication gate, Console surface, runtime protocol, or automation.

Any such enforcement belongs in a separate Feature with explicit `SPEC.md` impact and an accepted OpenSpec change.
Until then, repository review is the only enforcement mechanism.

## References

- `SPEC.md` sections 1.1, 1.4, 1.5, 3.4, 3.5, 5, 6, 7.2, 7.5, and 12.
- [ADR 0021](decisions/0021-explicit-tenant-model-grants-and-routing-snapshots.md) for Tenant model grants and routing snapshots.
- [ADR 0022](decisions/0022-request-deadline-ceiling-and-proxy-timeouts.md) for effective request deadlines.
- [ADR 0023](decisions/0023-platform-profiles-and-portable-core.md) for qualified profiles and support boundaries.
- [ADR 0025](decisions/0025-provider-neutral-worker-runtime-contract.md) for Worker Runtime contract ownership.
- [ADR 0026](decisions/0026-separate-capability-and-runtime-providers.md) for separate host-capability and runtime-provider authority.
- Issue #231 for the policy task and acceptance criteria.
- Issues #118 and #196 for pilot selection and evidence ownership.
- Issue #190 for reasoning behavior ownership.
- Issues #252 and #253 for the cold-start hold walkthrough.
