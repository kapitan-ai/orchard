## MODIFIED Requirements

### Requirement: API Clients receive explicit inference access

Bulk provisioning SHALL assign each created or updated API Client an explicit tenant-scoped `inference_client` Access Level by default, except that default mode SHALL refuse an existing reader-only client rather than silently broaden its authority.
The explicit `--access-level cluster_reader` mode SHALL instead create/ensure only the API Client's cluster-scoped reader grant, with no automatic inference grant, under the dedicated-client and atomic provisioning contract in [read-only-cluster-role](../read-only-cluster-role/spec.md#requirement-reader-provisioning-is-explicit-and-preserves-secret-custody).
Public `/v1/chat/completions` and `/v1/responses` requests authenticated by a service-account-owned API Token SHALL require the owning API Client to have the `inference_client` Access Level for the effective Tenant.
This changes `SPEC.md` §7.4.4 and §10.4 while preserving §5.2's explicit inference authorization; it SHALL NOT make a cluster-reader grant an inference permission.

#### Scenario: API Client can call inference after role assignment

- **WHEN** a request to `/v1/responses` uses a valid API Token owned by an enabled API Client with tenant-scoped `inference_client` access
- **THEN** Orchard authenticates the API Token
- **AND** Orchard authorizes the API Client for public inference before model resolution and tenant quota admission

#### Scenario: Reader provisioning does not enable inference

- **WHEN** an authorized operator explicitly provisions a dedicated API Client using `--access-level cluster_reader`
- **THEN** the client receives the cluster reader binding instead of an inference grant
- **AND** its valid token cannot invoke public inference merely because it can inspect cluster state

#### Scenario: Default repeat cannot silently widen a reader

- **WHEN** default bulk provisioning resolves an existing reader-only API Client
- **THEN** it refuses the batch without adding inference authority, creating a token, or changing that client's retained grants
