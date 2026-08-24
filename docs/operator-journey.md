# Orchard Operator Journey

This document describes how an operator moves from Orchard release media to a usable Controller, an available Node Agent, and a successful inference request.
It deliberately separates current supported behavior from target product intent.
Detailed commands remain in the packaging runbooks and are linked instead of repeated here.

`SPEC.md` remains the normative build contract.
This document is the durable journey and prioritization guide for closing the gap between that contract and the current build.

## Journey Vocabulary

The product-facing action may say "Add a worker", but the managed resource that enrolls is a **Node** running the **Node Agent**.
The **Worker Runtime** is a local MLX process supervised by that Node Agent and does not enroll independently.

A current Runtime Endpoint observation proves reachability only.
It does not prove Node identity, registration, admission, or scheduling authority.

The target journey keeps these states distinct:

1. Orchard is installed for an Install Role.
2. A Node proves its identity and becomes `registered`.
3. An administrator admits the registered Node.
4. A fresh healthy authenticated observation makes the Node `active`.
5. A model is available and loaded on an eligible Runtime Endpoint.
6. A real inference request succeeds.

## Layer 1: Current Supported Journey

### Current Status Boundary

The current app-primary DMG provides a verified `Orchard.app` and an app-owned root-authorized service lifecycle.
The app lifecycle supports `all`, `controller`, and `node-agent` Install Roles and preserves operator-owned state during update and default uninstall.
It does not yet provide an app setup wizard.

The packaged CLI provides `orchardctl init`, with `orchardctl first-run` as an alias, as a guided command sequencer for env-template generation, migration, local HTTPS, optional Console enablement, service start, and status.
The sequencer stops at a failed step and prints a resume command.
It does not collect an external Postgres DSN, edit BEAM identity or target values, automatically create Node trust, distribute a shared cookie, import a model to remote Macs, or replace the separate `orchardctl cluster init` first-admin operation.

After migrations on a Controller host, an operator initializes the distinct internal Node trust authority with `orchardctl nodes trust init`.
The command is local, leader-gated, idempotent, and reports only stable public identifiers and the runtime CA SPKI fingerprint.
It stores protected material under the support-root `config/node-trust` directory by default, with `ORCHARD_NODE_TRUST_ROOT` as an explicit path override.
It does not print or export CA or Controller private key material.

The current packaged multi-Mac path remains a first-cut private-network deployment and rehearsal path.
The packaged BEAM-first end state still uses manually distributed shared BEAM cookie material and an explicit Controller target list.
The secure enrollment tracer now provides owner-only Node Enrollment Bundles, pinned HTTPS Bootstrap Token redemption, protected local Node identity, Node Certificate issuance, certificate-backed registration, explicit audited admission, and authenticated gRPC compatibility activation.
The PR #87 post-merge smoke passed focused and full validation, coverage, real ephemeral HTTPS, and certificate-backed mTLS gRPC paths.
It did not exercise the root-owned packaged CLI, launchd, separate release processes, restart and reconnection, or a two-Mac enrollment journey, so that packaged acceptance gap remains open.
For a remote gRPC compatibility Node, `ORCHARD_NODE_AGENT_ADVERTISE_HOST` must name the Controller-reachable private address because a wildcard listen address is never persisted as a target.
Registration remains pending and non-schedulable until explicit admission, and admission remains non-schedulable until a fresh healthy identity-matched authenticated observation.

The authoritative current command details are in:

- [`packaging/dmg/README.md`](../packaging/dmg/README.md) for DMG verification and the app-owned lifecycle.
- [`packaging/README.md`](../packaging/README.md) for packaged configuration, external Postgres, transport, Console, service start, and the current multi-Mac first cut.
- [`docs/local-dev.md`](local-dev.md) for source-development topology and diagnostics.

### Common Prerequisites

Before a current packaged Controller can reach Console, the operator needs:

- An Apple Silicon Mac and local administrator authorization for system service installation.
- Operator-managed PostgreSQL 16 or newer because Managed Database Mode is not implemented.
- A public transport plan using direct HTTPS, an operator-managed reverse proxy, or explicit local generated HTTPS for a lab.
- A signed, notarized, stapled release-quality DMG and its checksum and signing sidecars.
- Protected storage for one-time cluster-admin and inference credentials.

A multi-Mac deployment also needs:

- Stable private IPv4 addresses on a trusted LAN or VPN.
- Private reachability for EPMD and the bounded BEAM distribution ports.
- A secure out-of-band channel for the shared BEAM cookie.
- A Model Bundle that can be staged at a path usable by the selected Node Agent host.

### Release Acquisition And Installation

1. Obtain the DMG distribution set and verify the checksum and mounted app trust evidence as described in the DMG runbook.
2. Copy `Orchard.app` to `/Applications` on every participating Mac.
3. Run the app-owned lifecycle helper with the required Install Role under explicit root authorization.
4. Treat the resulting state as installed but not configured because install deliberately starts no services.

The same generic DMG is used on Controller and worker Macs.
The selected Install Role decides which LaunchDaemons are installed and managed.

### Topology Differences

| Path | Install Role | Console outcome | Inference outcome | Material current differences |
|---|---|---|---|---|
| All-in-one | `all` | Available after Controller configuration, first-admin initialization, Console enablement, and service start. | Possible on the same Mac after Organization/API Token creation and local model import. | No cross-Mac cookie transfer or remote model path is needed, but external Postgres is still required in the current build. |
| Controller-only | `controller` | Available after the same Controller setup. | Not possible until at least one eligible Runtime Endpoint is configured and model-ready. | This path is useful for governance and Console setup but is not a complete first-inference topology. |
| Controller plus workers | `controller` on the Controller and `node-agent` on each worker Mac. | Available after Controller setup. | Technically exercisable through the current private-network first cut after explicit targets and worker-reachable model staging, but it is not the finished certificate-backed join journey. | Every worker adds a root-owned env edit, shared-cookie delivery, private-network checks, an explicit Controller target entry, and model staging. |

### Controller To First Console Access

The operator currently performs these outcomes, using the packaged runbook for commands:

1. Generate the Controller or all-role env template.
2. Set and validate the external `DATABASE_URL` and retain the generated `SECRET_KEY_BASE` unless deliberately rotating it.
3. Configure the Controller BEAM node name, cookie path, Runtime Endpoint targets when used, and public transport values.
4. Run migrations.
5. Run `orchardctl cluster init` with a protected output path to create the first cluster-admin API Client and one-time API Token.
6. Configure public HTTPS or a supported reverse proxy.
7. Enable Console through its interactive credential prompt when browser access is desired.
8. Start the role-selected services and verify status and readiness.
9. Open Console at the configured public host.

`orchardctl cluster init` is credential-only.
It does not provision public TLS, internal Node trust, a Bootstrap Token, or a BEAM cookie.

### Worker Bring-Up In The Current Multi-Mac First Cut

For each worker Mac, the operator currently:

1. Installs the `node-agent` role from the same DMG.
2. Generates the Node Agent env template.
3. Edits the root-owned env file with a unique BEAM node name, display name, shared cookie path, and worker settings.
4. Copies the same shared BEAM cookie to the protected path with owner-only permissions.
5. Starts the Node Agent and verifies local service state.
6. Adds the worker's BEAM node name to the Controller's explicit Runtime Endpoint target list and restarts or reconfigures the Controller as required.
7. Verifies transport reachability and Runtime Endpoint diagnostics.

This sequence does not execute the target `provisioned -> registered -> admitted -> active` trust flow.
The shared cookie is current transport access material and must not be described as Node identity or Node Enrollment.

### Organization, Model, And First Inference

After Console is reachable, the operator currently:

1. Creates an Organization.
2. Creates a tenant-direct API Token for bootstrap or manual use, or provisions an API Client and API Token for a named non-interactive principal.
3. Stores the one-time API Token output securely.
4. Imports and activates a Model Bundle.
5. Grants the Model to each approved Organization with `orchardctl models access grant`; activation alone authorizes nothing, and the Console Playground needs the same grant for the seeded `legacy` Tenant.
6. Verifies that the model source is reachable by the Node Agent that will load it.
7. Confirms `/v1/models` lists the granted active model.
8. Runs a small request through Playground or the Public Inference API.

The current local-file import path is not controller-hosted model distribution.
For a remote worker, the operator must pre-stage the same model at a usable path or use another worker-reachable source supported by the lower-level acquisition path.
Console and docs must not claim that one local import distributes the model across the cluster today.

### Current Friction Baseline

The counts below are structural estimates derived from the current one-Controller, one-worker runbooks.
They are not measured usability timings and may vary with the chosen TLS path.

| Friction | All-in-one baseline | Controller plus one worker baseline | Scaling behavior |
|---|---:|---:|---|
| Root-owned env files requiring operator review or edits | 2 | 2 | Adds 1 per worker. |
| Cross-Mac secret transfers | 0 | 1 shared-cookie transfer | Adds 1 destination per worker while the current shared-cookie path remains. |
| Explicit Runtime Endpoint target entries | 1 local target when configured | 1 remote target | Adds 1 entry per worker and requires Controller configuration ownership. |
| Macs requiring hands-on install/configuration | 1 | 2 | Adds 1 per worker. |
| Distinct secret categories requiring custody | `SECRET_KEY_BASE`, Console credential, cluster-admin output, and inference token | The all-in-one categories plus the shared BEAM cookie | Cookie distribution expands to every worker. |
| External prerequisites | Postgres, public transport, model bundle | The all-in-one set plus private addressing, port reachability, secure file transfer, and remote model availability | Network and model preparation recur per site or worker. |

The current repo has no accepted packaged benchmark for time-to-Console, time-to-first-worker-ready, or time-to-first-inference.
Future implementation PRs should record sanitized timings against the measurement definitions below rather than placing machine-specific evidence in this document.

### Current Recovery And Failure Points

| Failure point | Current observable symptom | Current recovery boundary |
|---|---|---|
| Missing or invalid external Postgres configuration | Migration, DB-backed CLI, or Controller readiness fails. | Correct the root-owned Controller env, verify Postgres independently, run migrations, and resume. |
| Partial TLS state | App lifecycle or Controller boot preflight fails closed. | Restore a complete set or deliberately regenerate the local lab set before retrying. |
| Legacy PKG ownership conflict | App lifecycle reports the `com.orchard.pkg` receipt blocker. | Remove or migrate the legacy installation before allowing app takeover. |
| BEAM cookie missing, mismatched, or too broadly readable | Node Agent or Controller transport validation fails. | Correct protected file ownership/mode and compare digests without exposing cookie contents. |
| EPMD or distribution port conflict | Runtime Endpoint connection fails or returns unreachable. | Align the private-network port configuration on every participating Mac and verify reachability. |
| Static target missing or wrong | Console diagnostics and scheduler cannot reach the intended Node Agent. | Correct the Controller target list and restart or reconfigure the Controller. |
| Endpoint observed but not trusted | Admission execution remains blocked and the endpoint is not schedulable. | Complete the future certificate-backed registration flow when implemented; observation alone is insufficient. |
| Lost first-admin credential | Admin API access is unavailable. | Use local `orchardctl cluster init --force-new-admin --yes` break-glass recovery and audit the new credential. |
| Model activated but not granted to the calling Organization | `/v1/models` omits the model and inference fails with `403 model_not_authorized`. | Grant the Tenant/Model pair with `orchardctl models access grant`; see [`../apps/orchard_cli/README.md`](../apps/orchard_cli/README.md). |
| Controller-local model source on a remote worker | Model acquisition fails with an unavailable path or artifact. | Pre-stage the verified bundle on the worker or provide a worker-reachable source. |
| Worker or Controller upgrade interrupts readiness | Service status, heartbeat, or requests become unavailable. | Follow the packaging runbook's service-level backup, preflight, update, and health checks, and use cordon, drain, and resume only where lifecycle-managed Nodes exist. |

## Layer 2: Target Operator Journey

The target experience is product intent.
It is not a claim about the current build.

### Target Principles

- One signed DMG installs every Orchard role.
- Product setup composes the same domain operations used by CLI and APIs rather than creating UI-only mutations.
- Installation, registration, Node Admission, activation, model readiness, and inference success remain visibly separate.
- Enrollment authenticates the Controller before sending a Bootstrap Token and authenticates the Node through a locally generated key and controller-signed Node Certificate.
- A Node Enrollment Bundle is one-use, short-lived, per-Node, inspectable, revocable, and auditable.
- A Node Enrollment Bundle never contains a BEAM cookie, cluster-admin credential, CA private key, Node private key, long-lived Node Certificate, database credential, or static target list.
- Production BEAM uses the enrolled Node and Controller Certificates plus one scoped BEAM Peer Grant for each exact Controller-to-Node pair.
- A BEAM Peer Grant is issued only after explicit Node Admission and never becomes Node identity, Node Enrollment material, or advisory-lock leadership proof.
- Production BEAM names and targets derive from trusted inventory rather than operator-maintained target lists.
- A failed production BEAM operation remains visible and never retries the same operation through gRPC compatibility.
- External Postgres remains an explicit prerequisite until Managed Database Mode is implemented.
- Setup ends with a real inference result, not merely green service processes.
- Every failure identifies the failed boundary and offers a safe resume path.

### Target All-In-One Journey

1. The operator verifies and installs `Orchard.app`.
2. The operator chooses **Create Orchard on this Mac** and authorizes the `all` Install Role.
3. Guided setup validates external Postgres, public transport, storage, and retained state.
4. Orchard runs migrations and the distinct first-admin and internal Node trust initialization operations.
5. Orchard enables Console and starts services.
6. The local Node Agent registers through the same identity model used by remote Nodes, and guided setup performs the same explicit audited Node Admission operation with confirmation inside the setup flow.
7. The operator creates or confirms an Organization and inference credential.
8. The operator imports one Model Bundle.
9. Orchard verifies, places, and loads the model on the local Node Agent.
10. Playground runs a small inference and shows the selected Node and model version.

### Target Developer Portal Access

1. The operator opens the Organization in Console and invites a Portal User by email.
2. Console shows the newly issued Portal Invite URL once, and the operator delivers it to that developer through an out-of-band channel.
3. While the Portal User remains invited, **Copy invite** reissues the invite with a fresh hashed token and extended expiry, invalidates the previous unused token, and shows the replacement URL once for copying.
4. The developer redeems the Portal Invite, chooses a password, and signs in to the Organization-scoped Developer Portal.
5. When access must end, the operator disables that Portal User, which ends only that user's portal sessions without automatically revoking minted API Keys.
6. The operator reviews that Portal User's portal-minted keys in Console and may revoke selected keys by displayed prefix when key access must also end.

### Target Controller-Only Journey

The Controller setup is identical through first Console access, but setup labels the cluster **No inference capacity** until a Node becomes active and model-ready.
Console offers **Add a worker** as the next action and does not imply that a healthy Controller alone can run inference.

### Target Controller Plus Worker Journey

1. The operator creates the Controller and reaches Console.
2. Console or CLI creates one Node Enrollment Bundle per worker Mac.
3. The bundle contains the Controller address, stable cluster and Node identifiers, a Controller trust pin, and one one-time Bootstrap Token with an expiry.
4. On each worker Mac, the operator installs the same DMG and chooses **Join existing Orchard**.
5. The worker previews the cluster identity and expiry, authorizes the `node-agent` Install Role, and imports the bundle.
6. The worker generates its private key locally, validates the pinned Controller, submits its CSR and bounded inventory, and receives a Node Certificate.
7. The worker reports **Registered, awaiting administrator approval**.
8. Console shows the registered Node, trust evidence, inventory, compatibility, and any blockers.
9. The operator previews and approves Node Admission, supplying a reason for the approved Controller Dispatch Ceiling and either accepting the default ceiling of `1` or setting an explicit one.
10. The Active Leader authorizes one BEAM Peer Grant for each eligible Controller-to-Node pair.
11. The worker retrieves the grants over certificate-authenticated control traffic and stores them in protected local identity state.
12. The Controller derives the canonical BEAM name and Runtime Endpoint target from trusted inventory.
13. A TLS distribution status probe using the exact certificates and Peer Grant produces a fresh healthy authenticated observation and advances the Node to `active`.
14. The operator imports a model once.
15. Orchard distributes the verified Artifact Bundle to selected admitted Nodes and shows transfer, verification, placement, and load progress.
16. Playground runs inference and shows the chosen Node, placement, model version, timing, and remediation when scheduling fails.

### Target Failure And Recovery Experience

Target setup must distinguish at least these conditions:

- Controller unreachable before any secret is sent.
- Controller trust-pin mismatch.
- Expired, consumed, revoked, wrong-cluster, or wrong-Node enrollment material.
- Registration response lost after the one-time token is consumed.
- Registration complete but admission still pending.
- Admission rejected with preserved decision history.
- Node Certificate issuance, storage, renewal, or revocation failure.
- BEAM Authorization Root missing or unrecoverable.
- BEAM Peer Grant delivery, expiry, generation, rotation, or revocation failure.
- Peer revocation recorded but distribution disconnection incomplete.
- Registered Node transport unreachable or runtime unhealthy.
- External Postgres unavailable or migrations behind.
- Model source unavailable, transfer interrupted, checksum mismatch, insufficient disk, or load failure.
- Public transport or Console authentication misconfiguration.
- Upgrade preflight blocked, drain incomplete, or post-update health verification failed.

Retry after a lost registration response must resume only when the enrollment identifier, locally held Node key, and CSR fingerprint match the consumed attempt.
Different key material must fail closed.

### Target Friction And Time Budgets

The following are shaping budgets for future acceptance tests, not current performance claims:

| Measure | Target outcome |
|---|---|
| Manual root-owned file edits for a normal all-in-one setup | 0 |
| Manual root-owned file edits for adding a worker | 0 |
| Shared cluster-secret transfers for adding a worker | 0 |
| Human admission decisions per worker | 1 by default |
| Machine-to-machine enrollment artifacts | 1 per worker, short-lived and one-use |
| Controller target-list edits per worker | 0 |
| Model imports per model version | 1 per cluster |
| Setup restart after a recoverable failure | 0, because setup resumes at the failed boundary |

Time measurements use these definitions:

- **Time-to-Console** starts when a verified app first launches setup and ends when authenticated Console renders Controller readiness.
- **Time-to-first-worker-ready** starts when a Node Enrollment Bundle is created and ends when the admitted Node has a fresh healthy authenticated Runtime Endpoint observation.
- **Time-to-first-inference** starts when Console is first ready and ends when Playground receives a successful terminal response.
- **Operator-active time** is the portion of each named elapsed metric during which setup awaits required operator input or the operator performs a required action.
- Model-byte transfer time and administrator waiting time are recorded separately so large artifacts and human delay do not hide workflow friction.

Initial acceptance targets should be no more than 15 minutes of operator-active time across the full time-to-Console boundary, no more than 10 minutes of operator-active time across the full time-to-first-worker-ready boundary, and no more than 10 minutes of operator-active time across the full time-to-first-inference boundary.
Each result must also report the complete elapsed metric plus model transfer, automated processing, and administrator waiting components rather than substituting a shorter start or earlier end state.
Implementation PRs should validate these budgets on supported release hardware and record sanitized evidence in the PR or issue.

## Layer 3: Gap Map And Ordered Improvement Slices

| Order | Slice | Operator value | Completion boundary |
|---:|---|---|---|
| 1 | Secure one-Controller, one-Node enrollment tracer | Replaces manual identity bootstrap with a real trusted `provisioned -> registered -> admitted -> active` path and gives existing admission UX a valid input. | Delivered in PR #87 through certificate-backed gRPC compatibility activation; root-owned packaged, restart, separate-release, and two-Mac acceptance remains open. |
| 2 | Enrollment hardening and production BEAM authorization | Makes enrollment recoverable, revocable, renewable, multi-Node capable, and compatible with the selected first-party runtime transport. | BEAM Peer Grant delivery, inventory-derived names and targets, TLS distribution activation, rotation, revocation, renewal, re-admission, decommission, Active/Standby behavior, and packaged acceptance are implemented and tested. |
| 3 | Controller-hosted model distribution | Removes per-worker model staging and makes cluster model readiness observable. | One verified Artifact Bundle import can be authorized, transferred, resumed, verified, placed, and loaded on selected admitted Nodes. |
| 4 | First-inference Playground tracer | Turns infrastructure readiness into user-visible useful work. | Playground completes one request through an admitted active Node and exposes model, placement, selected Node, request state, and scheduler explanation. |
| 5 | App-guided Controller and worker setup | Removes env editing and composes the stable CLI/domain operations into a coherent macOS experience. | App setup covers role authorization, prerequisite preflight, resumable progress, enrollment creation/import, admission status, model distribution progress, and first inference without UI-only mutation paths. |
| 6 | Managed Database Mode | Removes the largest remaining Controller prerequisite for the all-in-one path. | Orchard provisions, starts, monitors, backs up, and upgrades its supported local Postgres mode according to `SPEC.md`. |
| 7 | Coordinated upgrade and drain | Makes multi-Mac lifecycle maintenance safe and legible. | Preflight, cordon, drain, update, certificate/transport recovery, health verification, and resume are coordinated across the topology. |

### First Recommended Implementation Slice

The first narrow Section 3 BEAM Peer Grant tracer (task 3.2) is now implemented at the source-development level.
It remains CLI-first and covers one Controller and one Node Agent with real separate BEAM nodes and real TLS distribution, driven in source dev through `bin/source-dev-peer-grant` (see `docs/local-dev.md`).

The tracer starts from the certificate-backed `registered` Node delivered by PR #87.
It proves that no grant exists before admission, admission authorizes one exact pair grant, the Node retrieves it over gRPC/mTLS, the Runtime Endpoint target derives from trusted inventory without a static product target, and a BEAM status observation advances `admitted -> active`.
It also proves wrong certificate, wrong BEAM name, wrong pair secret, wrong generation, missing, expired, and revoked grant failures, deterministic delivery retry, visible transport state, and no automatic gRPC Runtime Endpoint fallback.
Connected-peer revocation while the Node is otherwise current, with proof of complete disconnection, remains in the task 3.3 future slice.

The tracer deliberately excludes Active/Standby failover, automated normal rotation, Controller Certificate and authorization-root rotation, multi-Node issuance, app UI, model distribution, dynamic address roaming, external Runtime Endpoints, and any claim of per-function BEAM sandboxing.
Only source-development single-Mac evidence is claimed; the root-owned packaged, separate-release, restart and reconnection, and two-Mac journey remains a later acceptance gate rather than evidence supplied by this contract workstream.

### Contract Impact

PR #87 completed the Section 2 secure enrollment implementation while preserving the packaged acceptance gap above.
ADR 0012 selects the hard-to-reverse production BEAM identity and authorization mechanism required before Section 3 implementation.
`SPEC.md` now defines Node Certificates as durable identity, BEAM Peer Grants as exact pair authorization, separate Active/Standby grants, trusted inventory targets, explicit rotation and revocation, the high-trust BEAM boundary, and the retained gRPC/mTLS roles.
The active OpenSpec package now records the completed first implementation tracer (task 3.2) at source-development level and keeps later Section 3 lifecycle acceptance explicit and unimplemented in this contract workstream.

No tactical `docs/DESIGN.md` update is needed until the app-guided setup slice defines reusable onboarding, progress, and recovery components.
