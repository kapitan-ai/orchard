## Context

`models.artifact_sha256` is the authoritative digest of the final Artifact Bundle tree.
Node acquisition currently recomputes the full tree digest for every cached load even when the cache has not changed.

## Goals / Non-Goals

**Goals:**

- Avoid repeated content reads for a previously verified unchanged cache.
- Detect ordinary edits, replacement, addition, removal, truncation, symlinks, and unsupported entries before accepting the fast path.
- Fall back to authoritative hashing for every uncertainty and retain current reacquisition behavior after a digest mismatch.
- Keep receipt persistence crash-safe and outside the Artifact Bundle digest domain.

**Non-Goals:**

- Defend against a privileged hostile writer that can manipulate both cache metadata and Node-owned receipts.
- Change the Catalog digest algorithm or Model Manifest contract.
- Add a cache database, transport field, or controller API.

## Decisions

### A receipt is acceleration evidence only

The receipt records a format version, the expected Catalog digest, a hash of the canonical cache path, and a hash of the complete sorted filesystem inventory.
The inventory includes directories and regular files with relative path, type, size, mode, ownership, device and inode identity, link count, modification time, and change time.
Staging promotion may change the cache root's rename metadata, so publication permits that one-time root transition only after all descendant evidence remains stable.
The published receipt binds the complete final root and descendant inventory, so later root metadata changes invalidate the fast path.
Because the portable `File.Stat` surface exposes whole-second timestamps, authoritative verification first normalizes every directory and regular-file modification time to a reserved historical value without changing bundle bytes.
The hash and published receipt bind the normalized complete inventory, so a later ordinary write changes the modification-time evidence even when it occurs immediately within the same change-time second.
The receipt never replaces or supplies the Catalog digest.

### Receipts live outside Artifact Bundles

Receipts live under the Node models root in a separate `.verification` namespace.
The receipt filename is derived from the canonical models root, the request-relative final path, and expected digest, so its identity remains stable when the final path is temporarily absent without exposing a local path or accepting an unvalidated request digest as a direct path component.

### Every uncertainty falls back to a stable full verification

A missing, malformed, unreadable, version-mismatched, path-mismatched, digest-mismatched, or inventory-mismatched receipt is removed and causes a full tree hash.
Full verification compares inventory fingerprints before and after hashing so concurrent ordinary mutation cannot publish a receipt for an unstable tree.
A crash before receipt publication leaves no trusted acceleration evidence and therefore causes a full hash on the next load.
Receipt temporary files receive owner-only permissions before atomic rename, and persistence errors expose only bounded reason atoms.
An atomic receipt-write failure is nonfatal because it leaves no acceleration evidence and forces a full hash on the next load.
Inventory or stability rejection during receipt publication fails the current acquisition closed and removes or reacquires the affected cache.
Any authoritative verification failure removes the prior receipt before returning or reacquiring.
Full verification of an existing cache removes the prior receipt before metadata normalization and fails closed if that revocation cannot be confirmed.
The initial post-normalization inventory accepts only entries that still carry the reserved modification time, closing the crash and concurrent-write windows before hashing begins.

### Operator force-full is process configuration

`ORCHARD_FORCE_FULL_MODEL_VERIFICATION=true` is the minimal cross-transport operator route.
It bypasses receipt eligibility for every cache load until the Node Agent restarts with the setting disabled.
This avoids widening Runtime Endpoint protocols or overloading unrelated force semantics.

## Risks / Trade-offs

- Metadata comparison is O(files) and still pays traversal and stat cost, but avoids reading artifact bytes.
- First verification performs an O(files) metadata-normalization pass before hashing.
- Filesystem metadata is not cryptographic evidence against a privileged writer with equivalent local authority.
- A metadata change that preserves correct content causes a full hash and receipt refresh, preferring integrity over maximum cache-hit rate.
- Atomic receipt publication does not remove the pre-existing time-of-check-to-use boundary between verification and worker file access.

## Migration Plan

Existing caches have no receipts and therefore receive one authoritative verification on their first load after upgrade.
Successful verification creates the receipt for subsequent unchanged loads.
Rollback ignores the sidecar namespace and restores full hashing on every load.
