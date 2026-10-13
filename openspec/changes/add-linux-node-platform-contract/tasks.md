## 1. Contract

- [x] 1.1 Audit current SPEC, profile, packaging, transport, lifecycle, and provider-neutral boundaries.
- [x] 1.2 Record ADR 0034 and the bounded Linux Node support matrix.
- [x] 1.3 Reconcile `SPEC.md` with the experimental profile and explicit non-support status.
- [x] 1.4 Strict-validate this OpenSpec change before implementation.

## 2. Package and host lifecycle

- [x] 2.1 Build the reproducible Node-only Debian artifact and relocated-root installer tests.
- [x] 2.2 Implement the systemd unit, dedicated identity, fixed paths, permissions, and exclusive identity-root ownership.
- [x] 2.3 Prove start, stop, restart, crash, reboot, upgrade, rollback, air-gap staging, default removal, and reinstall on an authorized Linux host.

## 3. Inventory, security, and diagnostics

- [x] 3.1 Implement bounded provider-neutral CPU, memory, disk, OS, kernel, and network observations.
- [x] 3.2 Implement separate NVIDIA and AMD accelerator observations with stable identities and no allocation authority.
- [x] 3.3 Prove certificate renewal/revocation, Peer Grant rotation, private-network reconnect/backoff, local secret permissions, and stale-observation fail-closed behavior through the accepted KAP-82 implementation and bounded single-host matrix; real mixed-host acceptance remains task 4.3.
- [ ] 3.4 Implement health, logs, metrics, lifecycle receipts, inventory snapshots, and redacted offline diagnostics with deterministic cleanup.

## 4. Custody and compatibility

- [ ] 4.1 Implement model-free process-group custody only to the extent accepted KAP-18 and KAP-26 contracts permit.
- [ ] 4.2 Prove reader-first `N`/`N-1` decoding and fail-closed old writers for generation-targeted work.
- [ ] 4.3 Run available model-free mixed-platform fixtures and record any real cross-host acceptance blocker.

## 5. Provider gate

- [ ] 5.1 Confirm all provider-neutral gates and exact one-H100 ownership prerequisites before starting a vLLM pilot.
- [ ] 5.2 If authorized separately, qualify one immutable model/profile at concurrency one without creating broader Linux, CUDA, vLLM, or model support.

## 6. Validation

- [x] 6.1 Run strict OpenSpec validation and review generated specifications for placeholder prose.
- [x] 6.2 Run formatting, compilation, Credo, Dialyzer, tests, coverage, Linux portable validation, and provider-neutral conformance.
- [x] 6.3 Obtain independent code review and resolve findings before handoff.
