## 1. Linear and contract

- [x] 1.1 Reframe KAP-82 with the two-layer private-network scope, ownership boundaries, exclusions, status, and relations.
- [x] 1.2 Audit current SPEC, ADR 0012, enrollment PKI, Peer Grant persistence, local custody, expiry guard, and retained gRPC control boundaries.
- [x] 1.3 Propose ADR 0035 and reconcile the required SPEC and OpenSpec deltas.
- [x] 1.4 Obtain explicit Repository Owner acceptance for seven-day certificate overlap, five-minute clock uncertainty, 30-day renewal lead, forced disconnect at certificate expiry, and the bounded reconnect policy.
- [ ] 1.5 Sync the accepted `add-linux-node-platform-contract` predecessor before archiving this change.

## 2. Transport-neutral credential lifecycle

- [x] 2.1 Implement exact CSR/key-possession, certificate issuance, renewal, overlap, revocation, decommission, and compromise-recovery authority.
- [x] 2.2 Implement owner-only crash-safe current/staged local certificate generations with pair validation, fsync, atomic publication, symlink refusal, and deterministic recovery.
- [x] 2.3 Implement current-authority checks and sanitized audit for every certificate transition and protected use.
- [x] 2.4 Test enrollment failures, exact identity, network and clock boundaries, crash points, overlap, authority loss, revocation, decommission, and Node/Controller restart.

## 3. Private-network BEAM mechanics

- [x] 3.1 Implement one-active/one-staged exact pair grants, bounded generation and atom creation, successor staging, cutover, and explicit predecessor disconnect.
- [x] 3.2 Implement current-generation reconnect, successor-only after committed cutover, with equal-jitter exponential backoff and fresh-observation completion.
- [x] 3.3 Deterministically test native BEAM connection identity plus current credential/grant generations; unchanged-authority reconnect proves a stale-observation escape before the remaining matrix can pass.
- [x] 3.4 Stop implementation and submit `add-node-agent-connection-incarnation-fence` as the narrow OpenSpec amendment; independent review proved a boot-only value cannot fence reconnects during the same Agent boot.
- [x] 3.5 Test stale certificate, local-identity, grant, and connection generations; version skew; wrong names and identities; expiry; revocation; reconnect; and fail-closed authority loss.

## 4. Boundaries and validation

- [x] 4.1 Prove reconnect never resumes output or retransmits an ambiguous Runtime Endpoint operation and adds no KAP-27 session/delivery semantics.
- [x] 4.2 Preserve KAP-28, KAP-18, KAP-26, KAP-84, and KAP-17 ownership boundaries in code, tests, and diagnostics.
- [x] 4.3 Run formatting, compilation, Credo, Dialyzer, focused and full tests, coverage, strict OpenSpec, and applicable Linux portable gates.
- [ ] 4.4 Obtain independent implementation review and real KAP-84 mixed-platform qualification separately before any support claim.
