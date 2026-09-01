## Context

The packaged wrapper currently evaluates `OrchardCLI.ControllerRPC.main_base64/1` inside the running Controller.
That bridge calls the CLI node-command handler, which in turn reaches Controller-owned previews, presenters, leadership checks, transactions, mutations, and audit operations through the generic standalone CLI Repo runtime.

The root release definition loads `orchard_cli`, but `apps/orchard_controller/mix.exs` has no source dependency on it.
The unwanted edge is therefore limited to release composition and the private packaged command path.

## Goals / Non-Goals

**Goals:**

- Remove all `OrchardCLI.*` modules and the `orchard_cli` application from the assembled Controller release.
- Preserve the exact local packaged node-command behavior and `ORCHARDCTL_RPC_V1` contract.
- Reuse the existing Controller domain implementation without duplicating mutations.
- Preserve standalone CLI parsing, help, output, and temporary Repo behavior.
- Prove the supported app update and rollback unit and fail-closed skew behavior.

**Non-Goals:**

- Add a remote operator API or select a normal authenticated CLI migration family.
- Broaden the packaged allowlist.
- Move unrelated direct-Repo CLI families or the generic standalone Repo runtime.
- Change node admission, lifecycle, leadership, audit, dispatch-capacity, or confirmation semantics.
- Change Worker Runtime ownership, provider evidence, host adapters, Linux packaging, or platform support.

## Decisions

### Controller owns one private compatibility path

The Controller application owns a private packaged RPC bridge and node-command compatibility handler.
The bridge preserves independent Base64 decoding, the existing closed allowlist, isolated group-leader execution, and exactly one versioned result envelope.

The compatibility handler retains the current parser, confirmations, and human and JSON presentation only for the implemented local migration baseline.
It invokes the existing Controller preview builders, shared presenters, leader authorization, transaction, mutation, audit, and mutation-time revalidation paths.
It is not a new durable public operator seam.

### Standalone CLI remains an adapter over the same compatibility implementation

`OrchardCLI.Commands.Nodes` keeps its public contract and continues to route host-local enrollment and trust commands itself.
All other node commands delegate to the Controller-owned compatibility implementation while supplying the unchanged `OrchardCLI.RepoRuntime` callback.

The generic standalone Repo runtime remains in `orchard_cli` because unrelated command families still require temporary Repo startup and standalone database guidance.
The packaged Controller path instead uses a narrow Controller-owned runner that requires the supervised Repo, performs the same reachability probe, and preserves database failure normalization without starting or stopping Repo ownership.

### The app payload is the compatibility unit

An old wrapper cannot call a Controller release that omits `OrchardCLI.ControllerRPC`, and a new wrapper cannot call an old release that lacks the Controller-owned entrypoint.
The supported macOS app lifecycle already stages one complete payload, snapshots all app-owned paths, stops services before replacement, installs the release tree before the wrapper tree, restores services only after the matching payload is present, and rolls every app-owned path back together on failure.

The wrapper and Controller release therefore activate and roll back as one payload transaction.
During the bounded replacement interval, either skew direction must fail closed because the Controller service is stopped or the private entrypoint is absent.
No compatibility shim under `OrchardCLI.*` is retained.

## Risks / Trade-offs

- **Compatibility code temporarily lives in the Controller.**
  The modules remain private and are explicitly superseded by later security-led command-family migrations.
- **A dependency is accidentally retained.**
  Build and real-release tests reject the CLI application, CLI library directory, any `OrchardCLI.*` beam, or a missing Controller-owned entrypoint.
- **Wrapper/release skew exposes partial authority.**
  Both skew directions are tested to fail closed without standalone fallback, and the existing app transaction remains the only supported activation and rollback path.
- **Command semantics drift during extraction.**
  Existing standalone tests remain in place, direct Controller tests cover the shared public seam, and packaged runtime and real-release tests preserve the wire and process behavior.

## Migration Plan

The new bridge, wrapper expression, and release composition land in one commit and one payload.
No database, state, credential, or operator data migration is required.
App-owned update stops selected services, applies the complete payload, and then restores the previously loaded compatible services.
Any caught failure restores the complete prior payload and service state, while abrupt termination is recovered by the next lifecycle mutation from the transaction journal.

## Open Questions

None.
