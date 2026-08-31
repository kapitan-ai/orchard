## Why

Orchard distinguishes catalog presence, Tenant publication, runtime availability, and product support, but it does not yet define the evidence and approval boundary for a local-model support claim.
Issue #231 requires a durable manual policy so a plausible response or a successful warm load cannot be presented as broader production support.

## What Changes

- Establish mandatory repository governance for local-model qualification records and scoped support claims.
- Bind each qualification to an exact model, runtime, artifact, and environment tuple plus a tested capability envelope.
- Separate artifact validation, runtime loading, meaningful generation, capability conformance, and production qualification.
- Require serving-mode, deadline, routing, residency, cold-start, and outcome evidence that cannot turn preloaded results into cold-load claims.
- Define approval, hold, withdrawal, supersession, requalification, and retention rules with explicit maintainer authority.
- Keep qualification and support claims out of product state, persistence, APIs, manifests, scheduling, Console behavior, runtime protocols, and automation.
- Preserve issue ownership for pilot selection, evidence execution, and reasoning behavior.

## Capabilities

### New Capabilities

- `model-qualification-governance`: Defines the repository-owned evidence, review, lifecycle, and scope contract for local-model support claims.

### Modified Capabilities

None.

## Impact

- SPEC.md impact: none - manual policy only.
- Documentation impact: adds the standing policy, reusable record and claim templates, and an accepted-on-merge decision record.
- Review impact: a local-model support claim requires a merged claim document backed by an approved exact-tuple qualification record.
- Runtime impact: none.
- Ownership impact: issues #118 and #196 retain pilot and evidence ownership, issue #190 retains reasoning behavior, and issues #252 and #253 remain defect and cost owners.
