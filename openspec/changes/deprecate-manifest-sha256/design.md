## Context

The Model Manifest currently requires a top-level `sha256` string in the shared Elixir domain and MLX worker parser.
BundleBuilder writes the placeholder `"pending"`, while the importer ignores that value and computes `models.artifact_sha256` from the staged tree after importer-owned manifest rewrites.
`Orchard.ArtifactBundle.tree_sha256/1` includes every regular file, so `manifest.json` and its exact final bytes are inside the authoritative digest domain.

Putting that same digest inside `manifest.json` would require a SHA-256 fixed point because writing the value changes the bytes being hashed.
The accepted owner decision is to remove this false authority from the manifest contract without changing the existing tree-hash algorithm or stored Catalog values.

No repo-owned minimum-worker-version or equivalent compatibility gate currently proves that every supported consumer accepts omission.
Producer emission must therefore remain unchanged during this compatibility phase.

## Goals / Non-Goals

**Goals:**

- Make top-level Model Manifest `sha256` optional in supported Elixir and MLX worker consumers while continuing to reject unknown keys.
- Make a present legacy value non-authoritative and prevent it from supplying, overriding, or being compared with `models.artifact_sha256`.
- Specify `models.artifact_sha256` as the digest of the final stored Artifact Bundle, including exact final `manifest.json` bytes after importer-owned rewrites.
- Prove through public seams that importer storage equals a fresh digest of the final stored tree.
- Document detached pre-import media verification and post-import Catalog verification as distinct checkpoints.
- Preserve BundleBuilder legacy emission until a separately accepted compatibility gate authorizes omission.

**Non-Goals:**

- A framed tree-hash v2 or any other new digest algorithm.
- Catalog rehashing, digest-version columns, or existing-row migration.
- `payload_sha256`, manifest canonicalization, or exclusion of manifest bytes.
- Runtime Endpoint distribution, Node acquisition verification, signatures, or archive-container digests.
- New capability negotiation or minimum-version policy.

## Decisions

### Keep one authoritative stored-tree digest

`models.artifact_sha256` remains the only authoritative Artifact Bundle digest.
The importer computes it after secure staging and every importer-owned mutation, then stores the result with the Catalog record.
This preserves existing data and ensures all final stored manifest bytes remain inside the digest domain.

Alternative: put the same value into `manifest.json`.
Rejected because the manifest is itself hashed and therefore creates an infeasible fixed-point contract.

Alternative: add `payload_sha256` or normalize the manifest during hashing.
Rejected because either approach creates another digest domain or changes the existing algorithm beyond issue #256.

### Treat manifest `sha256` as optional deprecated compatibility metadata

Consumers keep `sha256` in their closed set of known keys, accept omission, and preserve a present string only as compatibility metadata.
No import or Catalog path reads that field as integrity evidence.
Unknown top-level and nested keys remain rejected.

The shared fixture will declare top-level known, required, optional, and deprecated keys so Elixir and Python tests enforce the same schema posture.

### Retain producer emission until a separate compatibility gate

BundleBuilder continues emitting its existing legacy value in this change.
Removing the field is a separate follow-up that must cite repo-owned accepted evidence that every supported consumer version accepts manifests without it.
This change does not invent a capability protocol or infer safety from current source tests alone.

### Separate verification checkpoints

Before import, an operator verifies transferred Model Bundle media against detached evidence received through an independently trusted channel.
After import, Orchard recomputes the digest of the final stored Artifact Bundle and compares it with the authoritative Catalog value.
These values may differ when the importer rewrites `manifest.json`, so documentation must not present either checkpoint as a substitute for the other.
This change leaves Runtime Endpoint distribution, Node acquisition enforcement, signatures, and archive-container digest semantics to separate accepted work.

## Risks / Trade-offs

- [Risk] Existing manifests continue to display a misleading legacy value during the compatibility phase.
  - Mitigation: Mark it deprecated and non-authoritative in the contract, fixture, and operator documentation, and track producer omission as a precise gated follow-up.
- [Risk] Making the field optional in shared types could accidentally broaden other validation.
  - Mitigation: Keep closed-key validation and add explicit unknown-key regression coverage in both consumers.
- [Risk] Tests could compare against a digest calculated before importer rewrites.
  - Mitigation: Exercise the public importer and recompute from the final stored path returned through the Catalog record.
- [Risk] The historical unframed tree serialization has separate structural ambiguity.
  - Mitigation: Keep that security-hardening decision out of this slice and avoid presenting this PR as a new adversarial-transfer integrity design.

## Migration Plan

1. Update `SPEC.md`, the OpenSpec capability, shared fixture, and operator documentation.
2. Deploy consumer optionality across the shared Elixir manifest and MLX worker parser while BundleBuilder continues legacy emission.
3. Verify old manifests with `sha256` and new compatibility-test manifests without it across all supported consumers.
4. In a separate change, remove producer emission only after repo-owned accepted minimum-consumer evidence proves omission safe.

Rollback restores the previous consumer requirement and documentation without rehashing or migrating Catalog data.

## Open Questions

- Which future repo-owned release or support-policy artifact will constitute the accepted minimum-consumer-version gate for stopping BundleBuilder emission?
