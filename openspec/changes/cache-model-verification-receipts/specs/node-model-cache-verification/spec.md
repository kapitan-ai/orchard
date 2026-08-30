## ADDED Requirements

### Requirement: Authoritative first and fallback verification

Node acquisition SHALL verify first acquisition against the authoritative Catalog Artifact Bundle digest with `Orchard.ArtifactBundle.tree_sha256/1`.
It SHALL perform the same authoritative verification whenever durable receipt evidence is missing, invalid, or inconsistent with the current cache tree.

#### Scenario: First acquisition verifies exact bytes

- **WHEN** a Node materializes an Artifact Bundle that is not already cached
- **THEN** it computes the authoritative tree digest before promoting the staging directory

#### Scenario: Invalid receipt falls back to authoritative verification

- **WHEN** a cached Artifact Bundle has missing, malformed, mismatched, unreadable, or unstable verification evidence
- **THEN** the Node recomputes the authoritative tree digest before returning a cache hit

#### Scenario: Publication instability fails the acquisition closed

- **WHEN** the cache inventory changes after authoritative hashing but before receipt publication
- **THEN** the Node does not return the affected cache as verified and instead fails or reacquires it

#### Scenario: Failed reacquisition invalidates prior evidence

- **WHEN** staging verification fails for a cache path and digest that had an older receipt
- **THEN** the Node removes that receipt even when the final cache path is absent

#### Scenario: Existing receipt revocation is mandatory

- **WHEN** the Node cannot confirm removal of prior acceleration evidence before full verification
- **THEN** it fails the load before normalizing or hashing the existing cache

#### Scenario: Initial normalized inventory is unstable

- **WHEN** any bundle entry loses the reserved modification time before the initial inventory completes
- **THEN** the Node fails verification before hashing and does not publish a receipt

### Requirement: Path- and digest-bound fast path

A Node SHALL skip the full content hash only when a versioned receipt outside the Artifact Bundle binds the expected Catalog digest and canonical cache path to an unchanged complete filesystem inventory.
Before authoritative hashing, the Node SHALL normalize every bundle directory and regular-file modification time to a reserved historical value without changing bundle bytes.
Receipt publication SHALL bind that complete normalized inventory so an immediate later ordinary write cannot reuse the verified inventory fingerprint even when change times have only whole-second resolution.
The receipt SHALL remain acceleration evidence only and SHALL NOT modify or compete with the authoritative Artifact Bundle digest.

#### Scenario: Second unchanged load skips content hashing

- **WHEN** a previously verified cache has an exact receipt and inventory match
- **THEN** acquisition returns a cache hit without invoking `tree_sha256/1`

#### Scenario: Ordinary same-size mutation invalidates the fast path

- **WHEN** a shard is overwritten without changing its byte length
- **THEN** changed filesystem metadata invalidates the receipt and authoritative verification rejects the altered tree

#### Scenario: Immediate same-second mutation invalidates the fast path

- **WHEN** a shard is overwritten with equal-length bytes immediately after receipt publication
- **THEN** the reserved modification-time marker makes the inventory evidence distinct and the Node performs authoritative verification

#### Scenario: Truncation invalidates the fast path

- **WHEN** a shard is truncated after receipt publication
- **THEN** changed size and metadata invalidate the receipt and authoritative verification rejects the altered tree

### Requirement: Forced full verification

Operators SHALL have a documented Node Agent setting that bypasses receipts and recomputes the authoritative tree digest on every cache load.

#### Scenario: Operator forces verification

- **WHEN** `ORCHARD_FORCE_FULL_MODEL_VERIFICATION=true` is active
- **THEN** an unchanged receipt does not skip authoritative tree hashing

### Requirement: Verification-path observability

Node logs SHALL distinguish full, fast, invalidated, and failed verification paths.
Those logs SHALL NOT include local artifact paths, source URIs, digest values, or inventory contents.

#### Scenario: Logs identify the path safely

- **WHEN** acquisition takes any verification path
- **THEN** the log names that path and a bounded reason without exposing local filesystem or artifact integrity data
