## 1. Contract Reconciliation

- [ ] 1.1 Update `SPEC.md` §§4.2 through 4.4, 7.3.1, 7.4.1, 10.1 through 10.2, and 11.9 with retained provisional identity, append-only Enrollment generations, authorization, Action Preview, serialization, audit, and CLI behavior.
- [ ] 1.2 Narrow `docs/DESIGN.md` §15.5 with four explicit routes: eligible never-trusted placeholders use same-Node recovery, consumed Enrollments use matching-key and matching-CSR resume, trusted or non-provisioned Nodes use their applicable lifecycle or certificate workflow, and inconsistent history remains blocked without automatic replacement.
- [ ] 1.3 Reconcile `docs/operator-journey.md` and `openspec/changes/operator-first-run-journey` tasks 3.6 through 3.7 without marking unrelated hardening work complete.
- [ ] 1.4 Record closed result-field enums, versioned request-fingerprint canonicalization, same-Node linkage and current-pointer integrity constraints, and stable blocker, warning, consequence, and confirmation codes before implementing persistence or presenters.
- [ ] 1.5 Inventory every certificate, trust, registration, admission, and authorization evidence source and writer, and define the retention guarantee that makes negative history complete for the retained Node lifetime.
- [ ] 1.6 Prove whether certificate issuance can leave a usable external effect after its database transaction rolls back, or add a durable issuance-attempt fence before signing and make any started attempt permanently recovery-ineligible.
- [ ] 1.7 Require every eligibility-changing writer to take the shared Node-first lock and advance the recovery revision before any recovery surface is enabled.
- [ ] 1.8 Reject Controller or trust-authority scope changes, legacy Nodes without complete Enrollment history, and uncertain issuance for separately approved migration or repair rather than inferring eligibility.

## 2. Vertical TDD Slice One: Output-Failed Recovery

- [ ] 2.1 Add failing public-service tests for a coherent generation-1 `output_failed`, never-trusted `provisioned` Node, covering side-effect-free preview, administrator authorization, exact typed Node confirmation, reason and cause validation, stale preview, and audit rollback.
- [ ] 2.2 Add failing first-slice eligibility tests for every non-provisioned lifecycle, consumption or issuance evidence, admission or grant evidence, authority-scope change, missing or retention-ambiguous history, broken chain, fork, multiple current generations, cross-Node linkage, and unavailable evidence source.
- [ ] 2.3 Add generation, predecessor and successor, explicit current-generation, recovery-revision, and cluster-operation-scoped request-idempotency persistence with fail-closed constraints and no mixed-version writer window.
- [ ] 2.4 Backfill structurally valid registered and consumed history as generation `1` without making it recovery-eligible, and represent incomplete recovery history as blocked rather than aborting unrelated valid migration rows.
- [ ] 2.5 Refactor redemption, publication acknowledgement, output failure, stale-publication reconciliation, revocation, expiry, trust, and admission writers onto the shared Node-first lock order before enabling recovery.
- [ ] 2.6 Implement the shared preview and execution service so the first eligible recovery retains Node ID and display name, creates one `pending_publication` successor, invalidates the predecessor permanently, and returns bundle bytes only to the original execution response.
- [ ] 2.7 Add deterministic first-slice tests for recovery versus redemption, concurrent recoveries, matching and conflicting duplicate requests, decision precedence, audit rollback, publication success, proven delivery failure, lost publication-state acknowledgement, and stale reconciliation.
- [ ] 2.8 Prove that pending successors and every predecessor reject redemption, while uncertain publication reports successor redeemability as `unknown` and warns that the bundle may be redeemable without replaying it.
- [ ] 2.9 Preserve and rerun the existing consumed-enrollment matching-enrollment, matching-key, matching-CSR resume tests and mismatched-key or CSR rejection tests before exposing recovery.
- [ ] 2.10 Add failing CLI tests and implement `orchardctl nodes enrollment recover` for the output-failed case through the shared preview, presenter, confirmation, protected output, publication, and audit seams.
- [ ] 2.11 Add failing LiveView tests and implement the same output-failed case through one Action Preview panel, exact Node confirmation, one-time same-origin delivery, durable status restoration, and accessible failure copy.
- [ ] 2.12 Prove that preview and duplicate execution create no secret, Node, Enrollment, audit, reconciliation, or publication side effects beyond the single committed recovery operation.
- [ ] 2.13 Complete value-aware audit tests for free-form reason, request identifiers, actor provenance, and retained display name before enabling the CLI or LiveView recovery action.

## 3. Vertical TDD Slice Two: Remaining Eligible Causes

- [ ] 3.1 Add failing service, CLI, and LiveView tests for lost or inaccessible `issued` output, expired `issued` output, explicitly revoked output, and unresolved or stale `pending_publication` output.
- [ ] 3.2 Implement cause-specific preview and transition behavior without changing the retained identity, confirmation, audit, or publication contract.
- [ ] 3.3 Prove that expired `issued` predecessors record expiry, expired pending predecessors record recovery-time expiry evidence without fabricated publication, and revoked or output-failed predecessors retain their original terminal cause.
- [ ] 3.4 Prove that live predecessors transition to explicit supersession and that a late predecessor publication acknowledgement, stale reconciler, or stale bundle cannot restore or redeem predecessor authority.
- [ ] 3.5 Prove that Controller replacement or trust-authority rotation returns a stable blocked result and does not create a cross-authority successor.

## 4. Vertical TDD Slice Three: Full Concurrency Matrix

- [ ] 4.1 Add deterministic public-service race tests for recovery versus recovery, revocation, expiry, publication acknowledgement, and every remaining stale-reconciliation boundary.
- [ ] 4.2 Prove that the decision order resolves matching duplicates before current lifecycle or revision checks, while distinct requests observe ineligibility before stale preview.
- [ ] 4.3 Add same-request and same-fingerprint, same-request and different-fingerprint, unreadable-current-status, and newly authorized inspector tests without returning bundle bytes.
- [ ] 4.4 Prove one authoritative database decision time for validity and every state-specific expiry transition at exact boundary timestamps.
- [ ] 4.5 Prove that eventual reconciliation appends linked audit evidence without replaying bytes, rolling back consumed identity, restoring predecessors, or claiming unavailable state.

## 5. Vertical TDD Slice Four: CLI Display-Name Parity

- [ ] 5.1 Add failing CLI tests for one optional `--display-name NAME`, repeated flags, empty or malformed UTF-8, control characters, names over 128 bytes, whitespace normalization, and duplicate names before mutation.
- [ ] 5.2 Validate and normalize CLI display names before output reservation, trust reads, token generation, stale-publication reconciliation, audit, or database mutation.
- [ ] 5.3 Route valid CLI display names through the shared issuance validator used by Console and preserve generated-name behavior when the flag is omitted.
- [ ] 5.4 Separate stale-publication reconciliation from ordinary issuance so malformed or duplicate creation cannot mutate unrelated Enrollment state.
- [ ] 5.5 Prove that ordinary creation with an existing name never selects recovery and that recovery accepts only exact Node ID and the stored unchanged name.
- [ ] 5.6 Add stable human and JSON output tests that exclude Bootstrap Tokens, credential-derived and token-derived hashes, bundle contents, filesystem paths from audit, and raw caller-controlled provenance.

## 6. Security And Product Verification

- [ ] 6.1 Extend value-aware validation and redaction coverage beyond the first slice, keeping redaction digests distinct from prohibited credential-derived and token-derived hashes.
- [ ] 6.2 Run focused migration, domain, CLI, LiveView, client-hook, audit, redaction, malformed-input, and deterministic concurrency tests for every slice.
- [ ] 6.3 Verify light, dark, narrow viewport, keyboard, focus restoration, live-region, stale-preview reset, and reduced-motion behavior for all eligible and blocked Console states.
- [ ] 6.4 Run the complete Elixir workflow and coverage from the umbrella root, including both code-quality plugins with zero findings.
- [ ] 6.5 Run strict validation for this change and the complete OpenSpec tree after contract reconciliation.
- [ ] 6.6 Review generated main specs for placeholder prose and verify that strict validation is not presented as security, architecture, or production-readiness proof.
- [ ] 6.7 Obtain an exact-head independent security and domain review of the implementation diff and record only durable conclusions in repo-owned contracts, tests, or code.
