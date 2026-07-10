## 1. Contract And Public Interfaces

- [x] 1.1 Reconcile `SPEC.md` §11.1, §11.3, §11.4, §13.3, §13.4, and Milestone 0 with the app-primary DMG, app-owned lifecycle, retained PKG path, rollback, and retention contracts.
- [ ] 1.2 Create `packaging/service-lifecycle.json` as the shared role, installed-path, launchd-label, and retention-policy contract consumed by app and PKG contract tests.
- [ ] 1.3 Create `packaging/app/Package.swift`, `packaging/app/Sources/OrchardServiceLifecycle/**`, `packaging/app/Sources/OrchardServiceCLI/main.swift`, and `packaging/app/Sources/OrchardApp/main.swift` for the public `orchard-service install|update|uninstall|status` command surface and the app lifecycle entry point.
- [ ] 1.4 Add focused Swift tests under `packaging/app/Tests/OrchardServiceLifecycleTests/**` and executable integration coverage under `scripts/test-app-service-lifecycle.sh`.

## 2. Lifecycle TDD Tracer Bullets

- [ ] 2.1 RED then GREEN: reject invalid roles and non-root system mutations while allowing rootless dry-run and status.
- [ ] 2.2 RED then GREEN: install `all`, `controller`, and `node-agent` into a temporary root with the expected payload, links, plists, role marker, ownership intent, modes, and stopped initial service state.
- [ ] 2.3 RED then GREEN: update replaces only app-owned payloads, preserves operator state, and restores only services recorded as loaded before the transaction.
- [ ] 2.4 RED then GREEN: role transitions remove out-of-role plists and preserve the persisted role when no new role request is supplied.
- [ ] 2.5 RED then GREEN: injected failures at every commit phase restore payloads, links, plists, the role marker, and simulated launchd state.
- [ ] 2.6 RED then GREEN: uninstall removes app-owned files and markers while retaining config, data, models, bundles, logs, and operator-created support contents.
- [ ] 2.7 RED then GREEN: complete TLS state is preserved, partial TLS state fails preflight, no trust-store command is emitted, and a system-root PKG receipt blocks app-owned install, update, or uninstall.
- [ ] 2.8 RED then GREEN: status reports role, installation source, retained paths, launchd state, and PKG-receipt blockers without mutation.
- [ ] 2.9 Refactor transaction, filesystem, launchd, and plan responsibilities behind focused interfaces while all integration tests remain green.

## 3. Real App Assembly

- [ ] 3.1 RED then GREEN: create `packaging/app/Info.plist` and `scripts/build-app.sh` to assemble `Orchard.app` with a native main executable, native lifecycle helper, and embedded representative Orchard payload.
- [ ] 3.2 RED then GREEN: make the app entry point locate its embedded helper and payload through bundle-relative paths and emit a stable lifecycle invocation plan without prompting during tests.
- [ ] 3.3 RED then GREEN: assert app and PKG use the same role values, plist sources, wrapper sources, and installed-path manifest while PKG build tests remain green.

## 4. Inner-First Signing And Bundle Verification

- [ ] 4.1 RED then GREEN: create `scripts/sign-app.sh` to process nested app libraries and executables before helpers, the main executable, and the outer bundle without using `--deep`.
- [ ] 4.2 RED then GREEN: create `scripts/verify-app-signing.sh` to verify hardened runtime, entitlement class, identity, timestamp when required, nested closure, and the final strict app signature.
- [ ] 4.3 RED then GREEN: make `scripts/verify-app-signing.sh` generate a deterministic manifest with path, SHA-256, CDHash, Team ID, flags, and entitlement digest.
- [ ] 4.4 Run credential-free local ad hoc signing and strict bundle verification with `codesign`, then record Developer ID and Gatekeeper commands as credential-gated release checks.

## 5. Amore DMG Handoff

- [ ] 5.1 RED then GREEN: create `scripts/build-dmg.sh` to invoke Amore only after app verification and against a disposable app copy.
- [ ] 5.2 RED then GREEN: fail closed when before-and-after manifests show nested code or entitlement mutation.
- [ ] 5.3 RED then GREEN: verify the DMG format, mount it read-only, verify the mounted app, and detach it reliably on success or failure.
- [ ] 5.4 Run the installed `amore create-dmg --skip-notarization` local smoke without upload or credentials and document the exact credential-gated `amore release` handoff.

## 6. Documentation And Validation

- [ ] 6.1 Update `packaging/dmg/README.md`, `packaging/pkg/README.md`, `docs/tooling.md`, `AGENTS.md`, and nearby operator guidance with the Swift workflow, app and PKG boundaries, the explicit sudo invocation, lifecycle retention, signing, Amore CLI feature detection, and credential gates.
- [ ] 6.2 Run strict validation for `amore-dmg-service-lifecycle` and the all-change OpenSpec sweep.
- [ ] 6.3 Run `swift test --package-path packaging/app`, `scripts/test-app-service-lifecycle.sh`, the app-assembly/signing/DMG integration test, and existing PKG packaging tests.
- [ ] 6.4 Run the applicable full Elixir, native, formatting, linting, typing, test, and coverage workflows from `AGENTS.md`.
- [ ] 6.5 Verify the local built app with `plutil` and `codesign`; verify the DMG with `hdiutil` and mounted-app checks; run `spctl` and stapler validation only against a Developer ID signed and notarized artifact.
- [ ] 6.6 Run independent design and implementation review plus the configured automated validation pipeline until clean.
- [ ] 6.7 Commit, push, open a review-ready pull request, and record the exact root-authorization condition for the later real two-Mac install plus MLX generation smoke.
