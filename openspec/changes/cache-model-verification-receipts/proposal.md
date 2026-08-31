## Why

An unchanged cached model currently pays the full Artifact Bundle byte-hash cost on every load.
The measured field example for a roughly 28 GB artifact spent about 21 seconds hashing before worker startup.

## What Changes

- Preserve the Catalog digest and `Orchard.ArtifactBundle.tree_sha256/1` as the sole integrity authority.
- Persist a versioned path- and digest-bound verification receipt outside each Artifact Bundle after successful full verification.
- Allow unchanged filesystem inventory to skip the repeated byte walk while sending every missing or invalid receipt and every inventory mutation to authoritative verification.
- Add an operator configuration that forces full verification on every cache load.
- Add attributable logs for full, fast, invalidated, and failed verification paths without local filesystem paths or digest values.

## Capabilities

### New Capabilities

- `node-model-cache-verification`: Defines durable verification receipts, fail-closed invalidation, forced verification, and verification-path observability.

### Modified Capabilities

None.

## Impact

- Product contract: `SPEC.md` §6.7.
- Node Agent acquisition: `Orchard.Node.ModelAcquisition` and its ModelManager entry point.
- Runtime configuration and source-development operator guidance.
- No Catalog schema, manifest, digest algorithm, Runtime Endpoint protocol, or controller import behavior changes.
