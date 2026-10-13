## ADDED Requirements

### Requirement: Unmanaged Linux Source Development Is A Compatibility Workflow

Orchard SHALL distinguish `linux_unmanaged_source_development_compatibility`
from every platform, distribution, runtime-provider, and acceptance profile.
On Ubuntu 24.04 x86_64 it MAY run the portable Orchard applications from a
developer-owned checkout with the pinned developer toolchain, disposable local
development PostgreSQL, repo-local development identity, loopback HTTP, and the
loopback gRPC compatibility path.

The workflow SHALL remain unsupported and unqualified. It MUST NOT create or
imply production Node inventory, enrollment or admission, credentials, Peer
Grants, scheduling, placement or capacity authority, provider or model
activation, inference, root-owned singleton custody, fixed appliance roots,
systemd or cgroup enforcement, packaging, or support. Its evidence MUST NOT
satisfy or replace KAP-95, KAP-103, the accepted Ubuntu single-host profile, or
any Linux Controller, Linux Node, mixed-platform, or runtime-provider gate.

#### Scenario: Model-free developer smoke succeeds

- **WHEN** a contributor runs the all-in-one source command on Ubuntu 24.04 x86_64 with disposable loopback PostgreSQL, repo-local development identity, and the stub Worker backend
- **THEN** the Controller, Console, migrations, and local Runtime Endpoint compatibility observation may be validated
- **AND** no trusted or admitted production Node, schedulable capacity, Worker process, provider, model, or inference authority is created

#### Scenario: Appliance evidence is requested

- **WHEN** the unmanaged compatibility workflow completes successfully
- **THEN** Orchard continues to require every accepted Ubuntu single-host installation, custody, identity, service, database, recovery, qualification, and support gate
- **AND** the compatibility result cannot be represented as KAP-95 or KAP-103 evidence
