## Context

Orchard needs support claims that a reviewer can trace to exact evidence without turning qualification into a new product subsystem.
The same checkpoint can behave differently across quantization, renderer, runtime revision, Orchard revision, hardware, operating system, topology, deadlines, routing, residency, and cold-start conditions.
Catalog state and Tenant publication also answer different questions from qualification and support.

The policy therefore needs durable authority, but issue #231 explicitly excludes product state, persistence, APIs, scheduler gates, Console surfaces, runtime protocol changes, and automation.

## Goals / Non-Goals

**Goals:**

- Make support claims exact, capability-scoped, evidence-backed, reviewable, and reversible.
- Preserve explicit unknown and unsupported capabilities instead of inferring them from plausible output.
- Record when evidence was collected with cold loading permitted or with placement already preloaded.
- Provide a durable hold outcome for model defects, Orchard defects, environment deviations, and evidence gaps.
- Define reviewer, approver, retention, and requalification responsibility.

**Non-Goals:**

- Add qualification state to the running product.
- Select a pilot model or publish a default.
- Move evidence execution away from issues #118 and #196.
- Define reasoning behavior owned by issue #190.
- Store raw prompts, responses, credentials, logs, machine paths, or transient traces in Git.

## Decisions

### Use mandatory manual repository governance

An active support claim must be a merged repository document backed by an approved qualification record.
This gives collaborators a reviewable authority without creating runtime coupling or a parallel source of product state.

Alternative considered: advisory guidance.
This was rejected because advisory language cannot prevent a catalog entry, warm load, or one plausible response from being represented as production support.

Alternative considered: automated product enforcement.
This was rejected because issue #231 is a manual policy task and product enforcement would require separately approved behavior, persistence, API, and operational design.

### Qualify an exact tuple and capability envelope

The record binds checkpoint, quantization, tokenizer or renderer, runtime revision, Orchard revision, artifact digest, hardware, operating system, configuration, topology, and tested capability envelope.
A support claim may expose only the approved subset of that envelope.

Applicable Platform, Distribution, Runtime-Provider, and Acceptance Profile gates remain prerequisites.
Evidence for a target or experimental profile may be retained as draft or held evidence, but it cannot activate a support claim.

### Use explicit evidence and lifecycle states

Individual evidence results are `pass`, `fail`, `blocked`, or `not_tested`.
Qualification outcomes are `approved`, `hold_for_review`, `not_qualified`, `withdrawn`, or `superseded`.
A hold records the defect class, durable blocker, and exact resume condition.

Every measurement states `cold_load_permitted` or `placement_preloaded`.
Preloaded evidence cannot support a cold-load claim.

### Keep lifecycle changes atomic in repository review

A maintainer with merge authority approves, withdraws, or supersedes a record through a merged change.
When another qualified maintainer is available, the evidence author cannot be the sole reviewer and approver.
If a record stops being approved, every linked active claim changes lifecycle in the same merged change.

Requalification is triggered by material changes to the tuple, capability contract, protocol, admission budgets, cold-start cost, or a defect that can invalidate the evidence.
Retention rules preserve active and held evidence long enough to audit both current and withdrawn claims.

## Risks / Trade-offs

- Manual governance depends on reviewer discipline.
  The templates reduce omission risk, and merged review provides the enforcement boundary.
- Exact tuples create more records than a model-family label.
  This is deliberate because broader labels conceal runtime and environment differences.
- Evidence can remain held after a blocker closes.
  Closure triggers requalification; it does not retroactively convert historical evidence into approval.
