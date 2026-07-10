## 1. Documentation And Contract Shaping

- [x] 1.1 Add one durable operator-journey document with current behavior, target intent, topology differences, trust boundaries, recovery points, friction measures, and ordered slices.
- [x] 1.2 Add the canonical Node Enrollment Bundle glossary term and distinguish it from Bootstrap Token, Node Certificate, Node Admission, API Token, and BEAM cookie.
- [x] 1.3 Reconcile `SPEC.md` §10.6 so internal node-trust initialization is explicit and separate from credential-only `orchardctl cluster init`.
- [x] 1.4 Add this OpenSpec proposal, design, phased tasks, and normative requirement delta without implementing product code.

## 2. Secure Enrollment Tracer

- [ ] 2.1 Define versioned Node Enrollment persistence with one Bootstrap Token hash/prefix, enrollment id, issued/expiry/consumed/revoked/output-failed state, allocated Node reference, creator, expected Controller identity, CSR fingerprint, certificate issuance outcome, resume metadata, and sanitized audit metadata.
- [ ] 2.2 Add explicit internal node-trust initialization or admin import that is separate from first-admin credential initialization and exposes only public trust material to enrollment issuance.
- [ ] 2.3 Add a local Controller-host issuance command that depends on initialized or imported node trust and uses required exclusive owner-only output preflight, one-hour default expiry, 24-hour maximum expiry, leader-only write gating, one Node per bundle, hash-only persistence, cluster-scoped audit, and safe output-failure handling.
- [ ] 2.4 Implement `orchardctl node join --enrollment-bundle PATH` with local format/expiry checks, Controller trust-pin validation before credential transmission, local Node key generation and atomic protected persistence before redemption, CSR submission, atomic token consumption, Node Certificate issuance, and atomic certificate/runtime-trust persistence.
- [ ] 2.5 Reconcile `provisioned -> registered` only through allocated Node id, Bootstrap Token record, CSR, and issued certificate, never through hostname, IP address, BEAM node name, or target-string equality.
- [ ] 2.6 Integrate existing pending-admission preview and execution so the registered Node remains non-schedulable until explicit audited admission.
- [ ] 2.7 Derive the first authenticated Runtime Endpoint target from trusted Node inventory and advance `admitted -> active` only after a fresh healthy identity-matched observation.
- [ ] 2.8 Make the gRPC compatibility adapter certificate-backed for the first authenticated Runtime Endpoint proof by adding a Node Agent mTLS listener, Controller client credentials, CA validation, exact Node-id/controller-id SAN validation against enrollment-persisted identities, and fail-closed identity errors without changing the packaged BEAM-first end state.
- [ ] 2.9 Add public-interface tests for happy path, wrong HTTPS trust pin, wrong internal CA, wrong Node-id SAN, wrong Controller-id SAN, expired bundle, consumed bundle, revoked bundle, wrong cluster, wrong Node, concurrent redemption, crash before token consumption, crash after consumption before certificate issuance, crash after issuance before response delivery, crash before local certificate persistence, response loss with matching key/CSR resume, response loss with different key rejection, non-leader refusal, pending-admission exclusion, and authenticated activation.
- [ ] 2.10 Run the full Elixir workflow, strict OpenSpec validation, one-Controller/one-Node packaged smoke, and security review before handoff.

## 3. Enrollment Hardening And Production BEAM Identity

- [ ] 3.1 Add list, inspect, revoke, and reissue surfaces that never reveal the Bootstrap Token secret and preserve append-only audit history.
- [ ] 3.2 Add bounded cleanup for expired and consumed enrollment records while retaining required audit and decision evidence.
- [ ] 3.3 Add Node Certificate renewal, explicit revocation, decommission integration, and restart-safe local credential recovery.
- [ ] 3.4 Define and accept a node-bound, revocable production BEAM credential and authorization model that does not use one cluster-wide cookie as Node identity.
- [ ] 3.5 Replace static product target lists with targets derived from trusted registered/admitted Node inventory while preserving explicit source-development and compatibility overrides.
- [ ] 3.6 Validate multi-Node issuance, Active/Standby retries, controller failover, certificate rotation, rejected admission, re-admission, and decommission failure paths.

## 4. Controller-Hosted Model Distribution

- [ ] 4.1 Add an authenticated Controller artifact endpoint or Runtime Endpoint operation that authorizes admitted Nodes by Node Certificate and never serves artifacts to observations or admission candidates.
- [ ] 4.2 Import one verified Artifact Bundle into the Controller artifact root and expose cluster-level distribution eligibility separately from Catalog State.
- [ ] 4.3 Add resumable Node Agent transfer, checksum and optional signature verification, atomic cache placement, bounded retry, and disk-pressure failure handling.
- [ ] 4.4 Expose distribution, verification, Placement State, load progress, and stable failure codes through shared CLI, API, and Console semantics.
- [ ] 4.5 Test interrupted transfer, wrong hash, revoked Node Certificate, insufficient disk, duplicate request idempotency, partial cleanup, and air-gapped operation.

## 5. First-Inference Playground Tracer

- [ ] 5.1 Add a setup completion check that requires at least one active Node, an active model, a ready Model Placement, and a valid inference credential.
- [ ] 5.2 Run one small Playground request through the admitted authenticated Runtime Endpoint and display selected Node, model version, placement, request state, latency, and scheduler explanation.
- [ ] 5.3 Preserve failure separation for no active Node, model unavailable, transfer incomplete, load failure, scheduler exclusion, invalid credential, and public transport failure.
- [ ] 5.4 Record sanitized time-to-first-inference evidence with model-byte transfer and administrator waiting time reported separately.

## 6. App-Guided Setup

- [ ] 6.1 Update `docs/DESIGN.md` before implementation with reusable setup progress, blocker, resume, secret-output, and recovery patterns that follow existing Console and brand contracts.
- [ ] 6.2 Add **Create Orchard on this Mac** for `all` and `controller` roles, composing lifecycle authorization, license validation, external Postgres preflight, public transport, migrations, first-admin initialization, internal node trust initialization, Console enablement, start, and readiness.
- [ ] 6.3 Add **Join existing Orchard** for the `node-agent` role, composing bundle preview/import, trust validation, local key generation, registration, pending-admission status, rejection, and activation without UI-only mutations.
- [ ] 6.4 Add resumable setup checkpoints that preserve completed work and return to the exact failed boundary after app restart.
- [ ] 6.5 Add all-in-one, Controller-only, and Controller-plus-worker browser/app integration tests with accessibility and failure-state coverage.
- [ ] 6.6 Validate zero manual root-owned env edits and zero static Controller target-list edits for the normal target paths.

## 7. Managed Database Mode

- [ ] 7.1 Implement the `SPEC.md` Managed Database Mode contract behind the same Controller setup preflight and retained-state model.
- [ ] 7.2 Add backup, restore, health, startup ordering, upgrade, and recovery guidance before making Managed Database Mode the default all-in-one path.
- [ ] 7.3 Keep External Database Mode available and explicit for Controller-plus-worker and advanced deployments.

## 8. Coordinated Upgrade And Drain

- [ ] 8.1 Compose upgrade preflight, cordon, drain, app-owned update or PKG update, certificate and transport recovery, health verification, and resume into one observable workflow.
- [ ] 8.2 Preserve the `draining -> cordoned` cancel-drain recovery edge and never certify drain completion from a cancelled drain.
- [ ] 8.3 Add Controller, Node Agent, model-transfer, certificate-renewal, and Active/Standby failure recovery tests.

## 9. Acceptance Measurement

- [ ] 9.1 Record manual file edits, root-authorized workflows, cross-Mac secret transfers, static target edits, machines touched, external prerequisites, and model staging operations for each topology.
- [ ] 9.2 Measure complete elapsed and operator-active time-to-Console from verified app setup launch to authenticated Console readiness, with automated processing reported separately.
- [ ] 9.3 Measure complete elapsed and operator-active time-to-first-worker-ready from bundle creation to a fresh healthy authenticated observation on an admitted Node, with administrator waiting and automated processing reported separately.
- [ ] 9.4 Measure complete elapsed and operator-active time-to-first-inference from first Console readiness to successful Playground completion, with model-byte transfer, administrator waiting, and automated processing reported separately.
- [ ] 9.5 Store sanitized measurement evidence in the implementation PR or issue rather than committing machine-specific logs or evidence documents.
