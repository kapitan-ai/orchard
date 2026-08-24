# Security Policy

Orchard is a pre-release sovereign on-prem LLM orchestration platform for Apple Silicon macOS.
This policy defines the security-reporting path and the trust boundaries that reviewers may rely on today.

## Authority and scope

[`SPEC.md`](SPEC.md) is Orchard's top-level normative build contract.
This policy summarizes existing contract, implementation, and operator-documentation boundaries without weakening or amending `SPEC.md`.
If this policy conflicts with `SPEC.md`, an accepted decision record, or an accepted OpenSpec requirement, treat the conflict as a blocker and follow `SPEC.md` until the repository reconciles it.

Current implementation and operator-usable behavior are distinct from accepted target behavior.
Source-development and explicit compatibility paths are not production security guarantees.
Active packages under [`openspec/changes/`](openspec/changes/) remain proposed or partially implemented behavior until they are accepted and reconciled into durable repository truth.

A nested `SECURITY.md` may impose stricter reporting, validation, or trust requirements for its subtree.
A nested policy must not broaden support, relax this root policy, or override `SPEC.md`.

## Supported versions

Orchard does not currently publish a security-supported release line.
The repository identifies current development code as `0.5.0-dev`, but that identifier is not a released-version support commitment.
Security reports concerning current development code are welcome.

The Controller `N` and Node Agent `N` and `N-1` compatibility rule in `SPEC.md` is a target contract.
No concrete Current or Previous Supported Release Line should be inferred until the active release-governance work is accepted and implemented.

## Deployment and transport status

Orchard documents target topologies for all-in-one, Controller plus worker Nodes, and Active/Standby deployments.
Their present security and operator-usable status differs.

- Single-host source development through `bin/dev` is a development-only mode that uses loopback HTTP and loopback gRPC without production TLS.
- Split-role source development defaults to BEAM Runtime Endpoints with explicit shared cookie material, bounded distribution networking, and no automatic gRPC fallback.
- The source-development shared-cookie model is not the Production BEAM Operating Model.
- The macOS app lifecycle supports `all`, `controller`, and `node-agent` install roles, with Controller-bearing roles requiring operator-managed external Postgres.
- Native PKG is not a supported current distribution or security boundary. Legacy PKG material does not authorize installation or publication, and any future native package requires a fresh accepted OpenSpec proposal and implementing PR.
- The current app-installed multi-Mac shared-cookie BEAM path is a transitional first cut for trusted private networks and is not the production authorization model.
- Enrolled gRPC with exact certificate-bound mutual TLS is a compatibility and control path for trusted inventory.
- Explicit static or source-development gRPC targets may use plaintext compatibility and do not establish production Node trust.
- Production first-party BEAM requires exact certificate identity, trusted inventory, explicit admission, restricted networking, and an active scoped BEAM Peer Grant.
- Release-installed production Peer Grant acceptance, general multi-Node bootstrap, Managed Database Mode, complete air-gapped acceptance, and Active/Standby acceptance remain incomplete or target behavior where the current operator documentation says so.

## Intended attacker model

Orchard's security boundaries are intended to resist:

- unauthenticated remote callers;
- authenticated API callers attempting to exceed their Tenant or role authority;
- cross-Tenant data or authority access;
- spoofed forwarded headers and untrusted browser origins;
- Runtime Endpoint observations, enrollment candidates, or static targets attempting to become trusted Nodes without proof and admission;
- external, third-party, Tenant-controlled, or partially trusted compute attempting to enter the first-party BEAM mesh;
- malicious or malformed model archives attempting traversal, unsafe extraction, or artifact substitution;
- local unprivileged callers attempting to obtain secrets or cluster authority;
- unauthorized mutation of signed application contents, nested code, or entitlements after verification.

Orchard does not claim to isolate the cluster from an authorized controller-host administrator, a compromised Controller, administrative compromise of Postgres, or a compromised admitted service inside the High-trust BEAM Boundary.
Orchard also does not currently promise a sandbox that makes adversarial model formats or model runtime vulnerabilities harmless.

## Trusted Operator assumptions

Orchard assumes authorized Operators control the deployed Macs, private network, operating-system administration, Postgres administration, public TLS or reverse-proxy configuration, internal trust material, and release or artifact custody.
Operators are responsible for restricting host access, protecting credentials and owner-only files, selecting trusted model sources, preserving release evidence, and keeping explicit compatibility paths off untrusted networks.

Selected local `orchardctl` cluster operations execute with Controller runtime authority rather than an Admin API bearer token.
Controller-host operating-system and protected configuration access can therefore become cluster authority.
Loopback origin or ordinary local user access alone must not be treated as authorization for those operations.

## Principal and Node boundaries

### Tenants and API Clients

A Tenant is a governance boundary for model access, quotas, credentials, retention, and usage accounting.
It is not an isolation boundary against an authorized Operator, a controller-host administrator, or control-plane compromise.

Public inference APIs require a bearer API Token, the effective Tenant's inference authorization, and an enabled Tenant-to-Model access grant for the requested Model.
Model access is deny-by-default: no Tenant, including the seeded `legacy` Tenant, receives an automatic grant, and an ungranted Model is neither listed nor usable.
The current fail-closed Admin API implementation and [ADR 0004](docs/decisions/0004-admin-api-cluster-admin-auth.md) require an enabled service-account-owned API Token with a cluster-scoped `admin` role.
The broader Admin API summary in `SPEC.md` still refers to `admin` or `tenant-admin` authorization.
This policy does not resolve that contract conflict, and changing current behavior requires explicit reconciliation with `SPEC.md`.
The Operator API requires an enabled service-account-owned API Token with a cluster-scoped `operator` or `admin` role.
Tenant-direct and Tenant-scoped credentials do not grant cluster Admin or Operator API authority.

This policy intentionally does not specify API Token syntax, entropy, or hashing layout while the implementation and `SPEC.md` require reconciliation on those details.

### Node enrollment bootstrap

The Node enrollment redemption endpoint under `/bootstrap/v1/node-enrollments/:id/redeem` is outside the ordinary API bearer-token pipelines.
It relies on the one-time Bootstrap Token in a Node Enrollment Bundle and on pinned Controller trust before the Node sends that credential.
Successful redemption can register Node identity and issue a Node Certificate, but it cannot admit or schedule the Node.

### Observed, registered, admitted, and compromised Nodes

A Runtime Endpoint observation or matching address is untrusted operator-review evidence.
It does not establish Node identity, registration, admission, scheduling eligibility, or model-distribution authority.

A registered Node has proved enrollment identity but remains unschedulable until explicit audited Node Admission and the required policy inputs succeed.
An admitted Node becomes active only after a fresh healthy identity-matched observation.

Production distributed Erlang is a high-trust first-party boundary, not a method-level capability sandbox.
A scoped BEAM Peer Grant reduces credential blast radius but does not confine an authenticated peer to Runtime Endpoint methods.
A compromised admitted BEAM Node Agent remains inside the residual cluster trust boundary and should be treated as a cluster security incident.

External providers, third-party adapters, Tenant-controlled compute, and partially trusted machines must remain outside the BEAM mesh and use an explicit protocol adapter such as gRPC with mutual TLS.

### Local unprivileged callers

Local unprivileged callers are not trusted Operators.
They must not receive private keys, API Token secrets, bootstrap material, Peer Grants, database credentials, or Controller runtime authority.

Not every file under the packaged Orchard support root is confidential from local users.
Current package documentation makes product logs world-readable, so deployments must not rely on filesystem permissions alone to hide data that policy permits logs to contain.

## Component trust boundaries

### Controller

The Controller terminates public API and Console traffic and owns governance, admission, scheduling, dispatch, request state, stream relay, and cluster mutations.
Controller compromise or compromise of its administrative runtime should be treated as cluster-wide compromise.
All public token streams pass through the Controller, so its logging, payload-capture, and secret-handling rules are security boundaries.

### Orchard Console

The production Console is disabled by default.
When enabled in packaged production configuration, it requires configured Basic Auth.
Source development permits an unauthenticated Console and is not a production access model.

Console Basic Auth is separate from Tenant, Operator API, and Admin API bearer authorization.
The repository does not promise per-user Console identities or Tenant isolation within one authenticated Console session.
The Console Playground is an inference consumer that acts as the seeded `legacy` Tenant, so granting a Model for Playground use also authorizes every existing `legacy`-Tenant API credential for that Model on `/v1`; see [ADR 0021](docs/decisions/0021-explicit-tenant-model-grants-and-routing-snapshots.md).

### Node Agent and Worker Runtime

The Node Agent is the first-party Runtime Endpoint and the only component intended to be network reachable on a worker Mac.
Worker Runtimes remain Node-local subprocesses and must not be exposed directly on the LAN or WAN.
Worker process separation is not a promise that a malicious model or runtime exploit cannot compromise the Node Agent host.

### Runtime Endpoint transports

On the current enrolled gRPC compatibility path, the Controller verifies the exact Node certificate identity from trusted inventory, and the registered Node Agent verifies the exact enrolled Controller URI certificate identity.
Packaged acceptance of the full separated-service journey remains incomplete.
Static and source-development compatibility targets do not uniformly provide that guarantee.

Production BEAM authorization requires certificate identity and a scoped Peer Grant together.
BEAM transport or authorization failure must remain visible and must not replay the same operation automatically through gRPC.

### Postgres

Postgres is Orchard's sole durable persistence and coordination authority.
Administrative compromise of the Orchard database, its credentials, or its integrity should be treated as control-plane compromise.

Current Controller packages require operator-managed external Postgres.
Loopback rehearsal configurations may disable database TLS, while non-loopback production deployments should use authenticated TLS.
Managed Postgres and `verify-full` defaults remain target requirements where they are not yet delivered by current packaging.

### Model acquisition and filesystem

Model bundles, remote downloads, local imports, manifests, and archives are untrusted inputs until validated.
The current Node Agent stages content from its registered source adapters, computes a deterministic tree digest, and compares that digest with the expected artifact digest before promotion.
Local directory copies reject symlinks and unsupported file types, and the tar helper rejects traversal and unsafe entries when used.
The Controller's local import path computes a staged tree digest but does not compare it with a separately supplied expected artifact digest.
No current acquisition path authenticates publisher provenance.
The `SPEC.md` target requires hash validation, while detached model signatures remain optional.
A computed digest alone must not be represented as proof of a trusted publisher.

The MLX worker resolves MLX-LM from an audited full Git revision through the committed uv lock.
It rejects `model_file` configurations before upstream loading and explicitly disables remote code at the model and tokenizer boundaries.
The pinned source and these controls do not authenticate model publishers or make MLX execution a sandbox.

Secret-bearing environment files, private keys, Node identity custody, and Peer Grant material are intended to remain owner-only.
Certificates, metadata, logs, and other non-secret operational files may have broader read permissions.
Prompt and response bodies may be retained only according to the configured Tenant Payload Capture Mode, and secrets must never be logged.

### Public transport, proxies, and CORS

Production public traffic uses direct HTTPS or operator-managed reverse-proxy HTTPS.
Plain HTTP is restricted to loopback development or break-glass operation and is a degraded mode.

Forwarded headers are trusted only in reverse-proxy mode and only from configured trusted proxy networks.
CORS uses an explicit validated origin allowlist and is not an authentication or authorization control for non-browser clients.

### Signing and release evidence

Orchard's accepted distribution contract requires inner-first application signing, verification before DMG assembly, mounted-DMG verification, and checksum and signing evidence alongside the distribution.
Accepted controls detect unexpected mutation of signed nested code and entitlements and verify mounted contents against the verified build input.
Current checksum and JSON sidecars are not authenticated against coordinated substitution and must not be treated alone as release provenance.

These requirements do not mean every development build or currently available artifact is Developer ID signed, notarized, stapled, or published through a governed release process.
Candidate manifests, supported Release Lines, SBOM gates, immutable promotion, publication-byte verification, and publication-state controls in the active product-versioning change must not be treated as implemented policy until accepted and delivered.

## Reporting a vulnerability

Report suspected vulnerabilities privately to [najib@aisingapore.org](mailto:najib@aisingapore.org).
This is the interim Orchard security contact until a dedicated `security@kapitan.ai` address is available and this policy is updated.
Do not open a GitHub issue or post an unresolved vulnerability to any repository-wide channel.

Include:

- the affected commit, version identifier, or artifact identity;
- the deployment and transport mode;
- the affected component or trust boundary;
- minimal reproduction steps or a proof of concept;
- the expected and observed security impact;
- any relevant sanitized logs or traces.

Do not send production credentials, private keys, API Token secrets, Node Enrollment Bundles, Peer Grants, database connection strings, Tenant prompts or responses, or unrelated personal data.
If sensitive evidence is necessary, first ask the security contact to agree on a suitable transfer method.

Reports are especially useful when they show an authentication or authorization bypass, cross-Tenant exposure, trust or admission bypass, unintended BEAM authority, model-acquisition validation bypass, transport downgrade, secret leakage, or distribution-evidence tampering.
A documented development or compatibility limitation is not by itself a vulnerability, but bypassing its stated guardrails or expanding its documented blast radius is security-relevant.

## Disclosure expectations

Coordinate proposed public disclosure with the security contact while the report is unresolved.
This policy does not promise an acknowledgement or remediation timeline, a fixed embargo, coordinated-disclosure dates, CVE assignment, confidentiality, or monetary rewards.
Any future commitment of that kind requires an explicit owner decision and a policy update.

## Durable references

- [`SPEC.md`](SPEC.md) defines Orchard's normative architecture, security model, packaging, and compatibility contract.
- [`docs/glossary/CONTEXT.md`](docs/glossary/CONTEXT.md) defines Orchard's product and trust-boundary language.
- [`docs/decisions/0001-runtime-endpoints-beam-first.md`](docs/decisions/0001-runtime-endpoints-beam-first.md) defines transport-independent Runtime Endpoints and the source-development BEAM boundary.
- [`docs/decisions/0003-observed-runtime-endpoints-are-admission-candidates.md`](docs/decisions/0003-observed-runtime-endpoints-are-admission-candidates.md) separates observations from Node trust.
- [`docs/decisions/0004-admin-api-cluster-admin-auth.md`](docs/decisions/0004-admin-api-cluster-admin-auth.md) defines Admin API bearer authority.
- [`docs/decisions/0006-local-orchardctl-node-admission-authority.md`](docs/decisions/0006-local-orchardctl-node-admission-authority.md) defines the local Controller-runtime authority boundary.
- [`docs/decisions/0007-operator-api-operator-or-admin-auth.md`](docs/decisions/0007-operator-api-operator-or-admin-auth.md) defines Operator API bearer authority.
- [`docs/decisions/0011-first-admin-cluster-init.md`](docs/decisions/0011-first-admin-cluster-init.md) defines first-admin and break-glass local authority.
- [`docs/decisions/0012-scoped-beam-peer-grants.md`](docs/decisions/0012-scoped-beam-peer-grants.md) defines Production BEAM authorization and its residual high-trust boundary.
- [`docs/decisions/0027-remove-native-pkg-and-managed-handover.md`](docs/decisions/0027-remove-native-pkg-and-managed-handover.md) removes native PKG and the superseded managed handover protocol from the current security contract.
- [`openspec/specs/runtime-endpoints/spec.md`](openspec/specs/runtime-endpoints/spec.md) contains accepted Runtime Endpoint requirements.
- [`openspec/specs/packaging-deployment/spec.md`](openspec/specs/packaging-deployment/spec.md) and [`openspec/specs/app-distribution-lifecycle/spec.md`](openspec/specs/app-distribution-lifecycle/spec.md) contain accepted packaging and application-distribution requirements.
- [`docs/local-dev.md`](docs/local-dev.md) documents source-development behavior.
- [`packaging/README.md`](packaging/README.md) and [`packaging/dmg/README.md`](packaging/dmg/README.md) document current payload, app lifecycle, and distribution behavior.
