## Why

Orchard has a default-off BEAM Runtime Endpoint adapter, but source-dev still boots unnamed Mix VMs and configures only gRPC-shaped runtime targets.
A collaborator-reviewable operating model is needed before builders add split-role BEAM bootstrap, cookie handling, distribution networking, and BEAM-specific Runtime Endpoint target configuration.

## What Changes

- Define the Source-dev BEAM Operating Model for split-role `bin/dev-controller` and `bin/dev-node-agent` launches.
- Require named distributed BEAM nodes, long BEAM node names with IPv4-literal hosts, explicit shared cookie material, and bounded source-dev distribution networking when BEAM mode is selected.
- Define a BEAM-specific source-dev env/config surface using `ORCHARD_RUNTIME_ENDPOINT_TRANSPORT`, `ORCHARD_RUNTIME_ENDPOINT_TARGETS`, and `ORCHARD_BEAM_*` variables, while deferring `orchardctl env init` scaffolding for that surface to a separate CLI change.
- Keep `ORCHARD_RUNTIME_CLIENT_TARGETS` scoped to the gRPC Compatibility Adapter and prevent BEAM mode from silently falling back to gRPC for the same request.
- Require sanitized durable two-Mac smoke evidence under `docs/investigations/source-dev-beam-smoke-<date>.md` before any source-dev default promotion.
- Preserve all-in-one `bin/dev` on the current gRPC compatibility default in this change.
- Preserve gRPC compatibility as an explicitly selected adapter.
- Exclude product code, script, and runtime config implementation from this proposal package.
- Exclude production or packaged BEAM Distribution hardening, external Runtime Endpoint adapters, and any change to Postgres as Orchard's durable cluster truth.

## Capabilities

### New Capabilities

- `runtime-endpoints`: Adds source-dev BEAM operating model requirements for Runtime Endpoint transport selection, split-role BEAM bootstrap, cookie policy, distribution networking, failure behavior, and smoke evidence gates.

### Modified Capabilities

- None.
  No accepted OpenSpec capability specs exist yet.
  This change refines the existing Runtime Endpoint architecture direction into an apply-ready source-dev operating model.

## Impact

- SPEC.md impact: this change proposes behavior for the source-dev Runtime Endpoint operating model under the accepted BEAM-first Runtime Endpoint direction, without changing production packaging behavior or durable cluster truth.
- Affects future implementation work in `bin/dev-controller`, `bin/dev-node-agent`, source-dev config parsing, BEAM Runtime Endpoint target selection, cookie validation, distributed-node launch flags, tests, and local-dev documentation.
- Does not affect public inference APIs, request semantics, scheduler ranking policy, persisted schema, packaged launchd services, or Worker Runtime protocol behavior directly.
- Depends on the accepted direction in ADR 0001, `docs/decisions/0001-runtime-endpoints-beam-first.md`; the sibling `beam-first-runtime-endpoints` OpenSpec change remains companion architecture context, not an accepted capability spec dependency.
