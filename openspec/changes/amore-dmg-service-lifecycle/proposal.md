## Why

Orchard needs a direct-distribution macOS app path that proves the product can own privileged service installation without discarding the established PKG path.
The completed Amore spikes show that Amore is suitable for the outer DMG and release layer, while Orchard must retain control of payload assembly, nested signing, service lifecycle semantics, and verification.

## What Changes

- Build a real `Orchard.app` bundle with native Mach-O entry points and an embedded representative Orchard service payload.
- Add an app-owned lifecycle command for role-aware install, update, uninstall, and status behavior.
- Require root authorization for system-root mutation and provide a relocated root for deterministic, non-destructive integration tests.
- Add transactional update and uninstall semantics that preserve operator state by default and restore app-owned state after failures.
- Extend Orchard's inner-first signing and verification contract through the final app bundle seal.
- Add an Amore handoff that assembles a local DMG and fails closed if nested signatures or entitlements change.
- Keep the PKG path as a compatible parallel installer and offline/manual artifact.

## Capabilities

### New Capabilities

- `app-distribution-lifecycle`: Defines the app-primary DMG, app-owned privileged service lifecycle, transactional state handling, bundle signing, Amore handoff, and PKG compatibility boundary.

### Modified Capabilities

- None.

## Impact

- SPEC.md impact: update §11.1, §11.3, and §11.4 so the DMG is app-primary, the app owns a root-authorized service lifecycle, and PKG remains supported as a parallel compatibility path.
- SPEC.md impact: update §13.3 and §13.4 so an app lifecycle update or a PKG install can deliver supported service upgrades.
- Milestone impact: extend Milestone 0 packaging acceptance with sandboxed app lifecycle, rollback, retention, and mounted-DMG signature-preservation evidence.
- Packaging impact: add a SwiftPM macOS app/lifecycle package, app assembly scripts, signing verification, DMG assembly, and integration tests.
- Security impact: system-root mutation requires effective UID 0; tests use a relocated root; uninstall retains operator state by default; signing and Amore verification fail closed.
- Distribution impact: local DMG assembly is credential-free; Developer ID signing, notarization, stapling, hosting, and publication remain credential-gated release operations.
- OpenSpec dependency: this change builds on the completed `relax-enterprise-deployment-requirements` decision without modifying that still-unarchived change's `packaging-deployment` capability.
