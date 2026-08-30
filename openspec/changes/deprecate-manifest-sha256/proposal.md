## Why

Model Bundles currently emit a top-level `sha256` placeholder that consumers require but the importer ignores, while the authoritative Catalog digest is computed over the final stored Artifact Bundle, including `manifest.json`.
This ambiguity makes the manifest appear usable as integrity evidence even though embedding the same self-inclusive digest would require an infeasible fixed point.

## What Changes

- Deprecate top-level Model Manifest `sha256` and make it optional, accepted, and non-authoritative in supported Elixir and MLX worker consumers.
- Preserve `models.artifact_sha256` as the authoritative digest over the final stored Artifact Bundle, including the exact final bytes of `manifest.json` after importer-owned rewrites.
- Keep transitional BundleBuilder emission until a separately accepted compatibility gate proves every supported consumer accepts omission.
- Distinguish detached pre-import media verification from post-import Catalog verification in the product contract and operator documentation.
- Reconcile `SPEC.md` §§6.4-6.7 and §11.7 without changing the digest algorithm, rehashing Catalog rows, or adding a second payload digest.

## Capabilities

### New Capabilities

- `model-bundle-digest-contract`: Defines Model Manifest digest compatibility, authoritative Artifact Bundle hashing, and the distinct pre-import and post-import verification checkpoints.

### Modified Capabilities

None.

## Impact

- Product contract: `SPEC.md` §§6.4-6.7 and §11.7.
- Elixir consumers: shared `Orchard.ModelManifest`, Controller manifest parsing/import, and schema contract tests.
- Python consumer: MLX worker manifest parsing and schema contract tests.
- Shared manifest schema fixture and operator guidance in `docs/local-dev.md`.
- BundleBuilder continues emitting the legacy field in this change because no accepted minimum-worker-version gate proves removal safe.
- No Runtime Endpoint distribution, Node acquisition verification, signature, archive-container digest, Catalog migration, or digest-algorithm behavior changes.
