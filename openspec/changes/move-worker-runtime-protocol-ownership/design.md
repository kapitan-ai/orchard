## Context

The current Worker Runtime protobuf lives under the MLX implementation and generates only Python bindings.
The Node Agent consumes a manually maintained Elixir binding because ordinary Elixir generation maps the protobuf package to `Orchard.Worker.V1.*` while existing consumers use `Orchard.Node.Worker.V1.*`.
The accepted contract requires one provider-neutral source, reproducible bindings, committed-output drift rejection, and compatibility proof without changing the wire or runtime boundary.

## Goals / Non-Goals

**Goals:**

- Establish one provider-neutral Worker Runtime schema source.
- Generate every committed Python and Elixir binding deterministically with pinned tools.
- Preserve the existing Elixir module surface and imported shared-type identity.
- Prove the complete descriptor and reciprocal semantic decoding.
- Fail required validation for missing or drifted committed generated outputs.
- Select every consuming validation lane from protocol, generator, or binding changes.

**Non-Goals:**

- Add, remove, rename, or renumber protobuf messages, fields, or RPCs.
- Implement issue #327 reasoning encoding or any reasoning fixture or behavior.
- Add capability negotiation fields or normalized provider evidence.
- Change scheduling, placement, admission, retry, capacity, memory-budget, or prefix-cache policy.
- Replace gRPC over Unix-domain sockets, Node Agent subprocess custody, or Runtime Endpoint isolation.
- Add a runtime provider, publishable protocol package, Linux distribution, CUDA, or ROCm support.

## Decisions

### One neutral schema is the only protocol authority

The schema SHALL live at `proto/orchard/worker/v1/worker_runtime.proto`.
The previous MLX-owned file SHALL be removed after generators and consumers read the neutral path.
No provider-local copy, compatibility schema, or handwritten protocol transcription SHALL remain.

### One command generates both language surfaces

`mise exec -- mix proto.gen.worker` SHALL invoke the repository generator.
The pinned `grpcio-tools` environment SHALL live under the provider-neutral protocol tree and produce Python messages, Python gRPC stubs, and the descriptor set.
No runtime-provider package SHALL own the generator version or lock.
The pinned `protoc-gen-elixir` version SHALL produce the Elixir messages, service, and stub.

The generator SHALL apply only two mechanical Elixir namespace mappings.
It SHALL map the generated Worker Runtime namespace to `Orchard.Node.Worker.V1` and imported cluster types to the existing `Orchard.Cluster.V1` modules.
The protobuf package, full names, service name, message definitions, and method definitions SHALL remain generated from the canonical schema.

Changing consumer modules to a new namespace was rejected because it would create broad churn without improving the protocol contract.
Maintaining a second compatibility binding by hand was rejected because it would preserve the drift risk this change removes.

### Regeneration and drift checks share one output manifest

The generator SHALL own the exact list of committed generated outputs.
`mise exec -- mix proto.check.worker` SHALL generate into a temporary root and byte-compare every listed output with the committed tree.
The check SHALL fail for missing or changed outputs.
A negative regression SHALL copy clean outputs to a temporary fixture, introduce deliberate drift, and prove rejection without mutating the checkout.

### Compatibility evidence is semantic and descriptor-complete

The committed descriptor set SHALL include the Worker Runtime schema and all imported descriptors.
Tests SHALL assert every current message, field, field number, type, cardinality, import, RPC, request type, response type, and streaming flag.
Python and Elixir fixtures SHALL be encoded by their owning language bindings and decoded by the other language with semantic equality.
Tests SHALL not require two valid protobuf encoders to emit a universal canonical field order.

## Risks / Trade-offs

- **Generator namespace mapping changes unexpectedly** - the generator version is pinned and compatibility tests require the existing Elixir modules and imported shared types.
- **Generated output changes without schema intent** - the clean drift check byte-compares every committed output and deterministic generation runs twice.
- **A wire detail changes during the move** - the descriptor golden and literal complete-contract assertions fail.
- **A consuming lane is skipped** - classifier regressions require all five lanes for the neutral schema, generator/check inputs, and generated Elixir binding.

## Migration Plan

Move the unchanged schema, regenerate both language surfaces, add compatibility evidence, and remove the provider-local source in one pull request.
Run the existing provider-neutral, UDS, lifecycle, MLX, macOS, and packaging regressions at the same exact head.
No persisted state, operator action, protocol negotiation, or runtime rollout step is required.

## Open Questions

None.
