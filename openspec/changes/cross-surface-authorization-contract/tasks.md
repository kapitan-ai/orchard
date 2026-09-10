## 1. Contract acceptance and baseline reconciliation

All tasks below remain pending future implementation and acceptance.
OpenSpec artifact readiness is not implementation authorization or a COMPLETE family claim.

- [ ] 1.1 Review and accept the policy decisions in ADR 0033 and this package, retaining explicit API admission and Portal/Node/recovery boundaries.
- [ ] 1.2 Reconcile the proposal's affected `SPEC.md` sections, especially §7.1 Admin API admission wording, named RoleBindings, typed/schema-discriminated audit, the CLI family boundary, and §13 launch/ingress rollback enforcement.
- [ ] 1.3 Inventory all Console handlers/data paths and credential-family Console/API/CLI entry points; define a cluster-admin action-time guard or fail-closed behavior for non-migrated Console paths.
- [ ] 1.4 Implement the settled shared lock order, audit schema selection, 15-minute setup lifetime, explicit API/CLI envelopes, and currently unwired key-route delegates; verify password parameters and concrete storage/transport mechanisms before implementation review.

## 2. Named identity and session foundations

- [ ] 2.1 Add backward-compatible pending-setup Console identities, initial typed RoleBindings, revocable sessions, and explicit audit schema/actor columns without rewriting inference credentials or historical rows.
- [ ] 2.2 Implement authenticated identity creation/current-state inspection/invitation/disable endpoints, monotonic revision transitions, and closed initial-grant matrix; recovery must first obtain a usable API Client credential through existing `cluster init`, then use those APIs without a new local bypass.
- [ ] 2.3 Implement named login, pending-only setup redemption, identity disablement, session logout/revocation, explicit activity classes and absolute/idle expiry, epoch invalidation, generic rate-limited failures, HTTPS, cookie, CSRF, and origin protections; keep reset/reenablement deferred.
- [ ] 2.4 Cover historical idempotency versus current inspection, another admin's invitation replacement, redemption followed by disablement, recovery using a different API Client, setup replay/expiry, disabled identities, log-excluded delivery, exact idle deadlines, unattended sockets, delayed completion, and committed issuance with lost delivery.

## 3. Shared authorization and safe Console admission

- [ ] 3.1 Implement trusted caller contexts, closed action/resource/scope policy, and authority fences with post-lock revalidation of actor and target state.
- [ ] 3.2 Complete the retained-writer ledger for Portal/logout/epoch, Console session lifecycle, grant, batch rotation/provisioning, recovery, and direct-DB CLI paths; enforce common fences including absent-grant insertion and remove alternate standalone management revoke.
- [ ] 3.3 Add the inventoried action-time guards to non-migrated Console reads/events/parameters/async/subscription paths before allowing scoped named sessions.
- [ ] 3.4 Test unknown actions, forged actor/scope inputs, mixed grants, retained dormant privilege, owner/key grant unions including Tenant subjects, stale mounts, actor revocation while waiting on a lock, and target cluster-elevation races.
- [ ] 3.5 Prove Portal/inference credential independence, API Client versus human identity separation, and denial of Node/Bootstrap/Peer Grant material at management boundaries.

## 4. Complete credential inspection and revocation

- [ ] 4.1 Implement bounded metadata projections, filtered pagination, full-target privilege policy, current-session self-service, and no-store responses for all three credential kinds.
- [ ] 4.2 Implement domain-side-effect-free preview with the explicit Console idle-bookkeeping exception, revocation-relevant revisions excluding passive activity, confirmation/reason, self-revocation acknowledgement, current-state retries, and atomic scoped audit.
- [ ] 4.3 Expose the new Admin API routes under existing cluster-admin API Client admission and introduce specified-but-unwired key list/revoke delegates; close actual Console/scoped/unscoped governance entry points.
- [ ] 4.4 Implement explicit portable Controller/token-file selection, TLS/no-redirect credential policy, exact revision/reason/acknowledgement flags/envelopes, and legacy CLI alias server-side kind resolution with no local Repo fallback.
- [ ] 4.5 Cover admitted-authority parity, exact-prefix publication recovery after obtaining another credential, transmission-admission revocation, all unrevoked target states, already-revoked shape checks, scope-before-revision, self-revocation, audit rollback, and lost response.
- [ ] 4.6 Verify explicit session creation/logout and cutover lifecycle audit, null session-target `api_key_id`, retained historical references, privileged target scopes, `api_key.revoked` compatibility, closed schemas, and secret exclusion.

## 5. Cutover, validation, and completion

- [ ] 5.1 Implement the three cutover/rollback states and whole action-policy/session/fence/audit-writer version, live current-epoch admin Session proof, all non-retired eligible Controller evidence, and external launch/ingress/database-isolation gates.
- [ ] 5.2 Test old writers despite Console disablement, stale Controller evidence, expired admin proof, direct HTTP/LiveView, isolation, interrupted rollback, and restricted setup/fresh-login restoration with no surviving session, including audit failure before general access.
- [ ] 5.3 Verify exact named-session activation/restoration routes, state/version body preconditions, typed confirmation, rejection of API Bearer/session-ID substitution, and pre-cutover named login outside Basic Auth.
- [ ] 5.4 Run targeted security and concurrency tests first, then the complete applicable Elixir workflow from `AGENTS.md`: `mise exec -- mix format`, `mise exec -- mix compile --warnings-as-errors`, `mise exec -- mix credo --strict`, `mise exec -- mix dialyzer`, Darwin helper staging when applicable, `mise exec -- mix test`, and `mise exec -- mix test --cover`.
- [ ] 5.5 Run applicable asset/browser validation after reading `docs/DESIGN.md`; verify stale-session and scope behavior at the real LiveView boundary and run portable CLI parity checks.
- [ ] 5.6 Run `OPENSPEC_TELEMETRY=0 mise exec -- npm run openspec -- validate cross-surface-authorization-contract --type change --strict --no-interactive` and `git diff --check`, recording actual outcomes in the implementation review.
- [ ] 5.7 Mark only this family COMPLETE after reviewed parity, failure, coverage, cutover, and alternate-path closure evidence; explicitly retain deferred Tenant-admin machine admission and other family migration status.
- [ ] 5.8 After accepted sync or archive, run `OPENSPEC_TELEMETRY=0 mise exec -- npm run openspec -- validate --all --strict --no-interactive` and review generated main specs to replace placeholder prose such as `Purpose TBD`.
