## ADDED Requirements

### Requirement: Runtime Target Diagnostics Are Redacted Observations

Under SPEC.md §4.6.1 and Milestone 9, existing runtime snapshots and shared NodeStatus SHALL expose an additive nullable diagnostics block with only bounded evidence categories, source categories, timestamps, ages, counts and health/lifecycle observation categories. Registered Nodes and admission candidates SHALL NOT acquire host inventory from persistence or name-based matching. Projection SHALL perform no I/O or authority mutation.

#### Scenario: Fresh CPU and accelerator evidence

- **WHEN** a runtime target returns valid fresh CPU-only, NVIDIA or AMD inventory
- **THEN** diagnostics expose only allowlisted observations with distinct vendor provenance
- **AND** NVIDIA/AMD counts, including zero, require matching vendor enums and `nvidia-smi`/`rocm-smi` evidence respectively on the provider and every contributing device
- **AND** no capacity, device binding, readiness, admission, custody, release or qualification follows

#### Scenario: Vendor source provenance fails closed

- **WHEN** provider or contributing-device sources are missing, unknown, opposite-vendor, non-vendor or inconsistent
- **THEN** the vendor count is null rather than positive or zero
- **AND** re-normalized atom-key or JSON sections admit NVIDIA counts only with `nvidia_probe` and AMD counts only with `amd_probe`
- **AND** fresh matching empty-device observations retain zero counts without changing freshness, oldest-contributing-time or size bounds

#### Scenario: Old reader or old Agent

- **WHEN** a reader omits the additive field or an Agent omits inventory
- **THEN** missing diagnostics normalize to null and missing inventory to absent evidence
- **AND** registered-node CLI JSON and shared NodeStatus agree

### Requirement: Operator Health Exposes The Retained Diagnostic Block

Authenticated `GET /ops/v1/health` SHALL include nullable `runtime.diagnostics`, re-normalized with the shared closed allowlist and source-timestamp freshness bounds from its single existing runtime snapshot read. Failed snapshots SHALL yield null regardless of injected diagnostics. Missing/legacy blocks and unknown diagnostic schemas SHALL yield null. The additive field SHALL NOT change health status, readiness, no-store caching or authorization.

#### Scenario: Authorized operator reads observations

- **WHEN** a cluster-scoped Operator or admin requests health with a successful runtime snapshot
- **THEN** the response includes only allowlisted diagnostic evidence with preserved timestamps and recomputed ages
- **AND** stale, future or invalid evidence cannot contribute positive counts or current runtime health categories
- **AND** no additional runtime read or probe occurs

#### Scenario: Failed or legacy snapshot

- **WHEN** the runtime snapshot fails, omits diagnostics or carries an invalid/unknown diagnostic schema
- **THEN** runtime diagnostics are null without changing the readiness-derived HTTP status

#### Scenario: Unauthorized or public health request

- **WHEN** an unauthenticated, tenant-only or non-operator caller requests operator health
- **THEN** authorization rejects the request before runtime diagnostics are read
- **AND** public `/health/ready` continues to return only status without runtime diagnostics or a runtime read

### Requirement: Diagnostic Evidence Fails Closed And Remains Bounded

Projection SHALL reject unknown schemas, malformed and oversized inventory before unbounded traversal or encoding. It SHALL omit sensitive identities, network addresses, raw protobuf fields, paths, arbitrary messages, credentials, environment, prompts, responses and tenant data. Source timestamps SHALL be preserved; stale, future, absent or invalid timestamps SHALL NOT produce fresh positive evidence. Re-normalization SHALL NOT manufacture freshness.

#### Scenario: Malicious nested input

- **WHEN** input contains oversized nested structures, unknown fields or sensitive strings
- **THEN** the projection is bounded and either drops those fields or returns invalid evidence

#### Scenario: Stale or future evidence

- **WHEN** an inventory or section timestamp is stale, future or invalid
- **THEN** counts are unavailable rather than healthy, free or zero capacity

### Requirement: Retained Surfaces Do Not Restore Support Bundles

Diagnostics SHALL reuse existing status reads and SHALL NOT add OS/vendor probes, unrestricted runtime calls, support commands, archives, exports, staging or manifests. Public readiness SHALL remain status-only and existing authorization boundaries SHALL remain unchanged.

#### Scenario: Former support command

- **WHEN** an operator invokes the retired support namespace
- **THEN** it remains an unknown command with no artifact side effect
