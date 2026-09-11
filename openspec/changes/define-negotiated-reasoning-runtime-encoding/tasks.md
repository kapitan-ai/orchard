# Tasks

## 1. Contract acceptance

- [x] 1.1 Record the approved narrow reasoning-only eligibility exception, unary preparation proof, live-probe-only evidence, usage ownership split, canonical retry source, and dormant activation gate.
- [x] 1.2 Review the fresh-base protocol allocation: `WorkerCapabilities` fields 1-7 used, 8 reserved for the deferred loaded binding, and 9 available.
- [x] 1.3 Run change-scoped strict OpenSpec validation.
- [x] 1.4 Run all-change strict OpenSpec validation and inspect generated main specs for placeholder prose.

## 2. Prerequisites and schema handoff

- [x] 2.1 Wait for PR #401 to merge; do not start schema or runtime work from an unmerged canonical-identity branch.
- [ ] 2.2 After this contract is accepted, re-confirm the approved field allocations and add the shared reasoning protocol source, protocol declarations, generated bindings, and reciprocal fixtures atomically.
- [ ] 2.3 Preserve legacy operation and event field sets for every older or non-advertising binding; add explicit opt-in reasoning observation coverage.

## 3. Dormant implementation handoff

- [ ] 3.1 Implement loaded-binding-scoped live reasoning evidence, remaining-freshness handling, Tier 0-only eligibility, and unary preparation with single-use authorization.
- [ ] 3.1a Enforce the bounded live wave (reachable loaded-placement universe, at most four probes in flight advancing down the §5.7 ranking order, one 2000 ms wave deadline, no transport retry) with a determinism test proving identical passes advance through the same order.
- [ ] 3.1b Cover the three probe result classes and the outcome split: no loaded placement, or a universe in which every placement returned confirmed non-support (an explicit unsupported response, a non-advertising `N-1` response, or valid evidence with an absent or mismatched tuple), fails closed as incompatible, while a proving-but-undispatchable placement, an unknown-class result (malformed evidence, timeout, task exit, transport failure, or a missing or incomplete response), an elapsed wave deadline, or a withheld Node keeps the retryable queue-waitable busy path.
- [ ] 3.1e Prove the wave withholds targets that are not scheduler-fresh, fail §5.5's health condition, or are suppressed at either §5.10 breaker scope, that withholding preserves suppression, and that a withheld or unreachable placement blocks the permanent incompatibility conclusion.
- [ ] 3.1f Prove the probe health gate resolves through §5.5's condition rather than a reasoning-specific one, covering a `degraded` Node under `legacy_pre_cutover` and the same Node once that decision changes.
- [ ] 3.1c Prove the advancing window reaches capable placements ranked below incapable ones and that a lower-ranked proof never wins over an unresolved higher-ranked probe.
- [ ] 3.1d Enforce the per-logical-Request wave budget: a pre-start busy re-grant runs no wave, carries a hint only, revalidates through `PrepareInference`, and terminalizes under the existing queue-wait budget; both waves plus queue wait consume the single §12.4 loaded-only deadline.
- [ ] 3.2 Implement D1, D2, and D3 with direct failure-path and both-attempt regression coverage.
- [ ] 3.3 Pin automatic and full-capture operator retry to `canonical_request["reasoning"]`; return `retry_source_unavailable` rather than rerendering or adding a column.
- [ ] 3.4 Keep production registries empty and prove no production tuple is advertised before #328 plus qualification governance authorize activation.
- [x] 3.5 Record D4 (`terminal_conformance + internal_error`) as a #328 handoff without implementing it here.

## 4. Future validation

- [ ] 4.1 Run the applicable protocol drift, reciprocal N/N-1 fixture, provider-neutral, Elixir, native, and coverage workflows after implementation.
- [ ] 4.2 Re-run strict change and all-change OpenSpec validation after implementation and before PR handoff.
