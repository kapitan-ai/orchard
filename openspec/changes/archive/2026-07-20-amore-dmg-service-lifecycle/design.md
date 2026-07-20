## Context

`SPEC.md` currently requires both `/Applications/Orchard.app` and a DMG containing `Orchard.pkg`, but the repository has no app source or app-bundle assembly path.
The existing PKG path builds the production releases and native helper environments, signs nested Mach-O payloads inner-first, installs role-selected LaunchDaemons, and preserves operator configuration.
Its preinstall and postinstall scripts are not transactional: a failure after services stop leaves them stopped until the operator fixes the cause and reruns the installer.

The Amore spikes and current upstream documentation agree that Amore can consume a prebuilt app, assemble a DMG, notarize, staple, host, and publish it.
Amore also signs app input during its full release workflow, but its traversal and preservation of existing nested signatures and entitlements are undocumented.
Orchard therefore needs an explicit before-and-after verification boundary.

## Goals

- Prove one end-to-end app distribution path from a real app bundle through a mounted local Amore DMG.
- Prove role-aware install, update, uninstall, status, state preservation, rollback, and retention without mutating the host.
- Preserve Orchard-owned inner-first signing and final app-bundle verification.
- Keep PKG output and behavior compatible while the app path proves parity.

## Non-Goals

- Sparkle integration or broad updater UX.
- The full tray and menu-bar feature set in `SPEC.md` §11.8.
- MDM, Jamf, managed-device workflows, or Homebrew distribution.
- Managed Postgres.
- Real root installation, sudo or Touch ID prompts, real notarization, upload, publication, or production keychain mutation.
- The two-Mac install and MLX generation smoke.

## Approaches Considered

### Separate lifecycle, signing, and Amore pull requests

This produces the smallest individual diffs.
It is rejected for the first slice because no pull request proves that app-owned lifecycle artifacts survive the undocumented Amore signing boundary.

### Full production Orchard app

This would include complete tray UX, privileged authorization UI, real installation, notarization, and publication.
It is rejected because it broadens the first proof into unrelated product surfaces and credential-gated work.

### Thin end-to-end tracer bullet

This change builds a minimal native app, a complete sandboxed lifecycle engine, bundle-aware signing verification, and a local Amore DMG handoff.
This is the selected approach because every critical boundary is exercised while the production UI, credentials, and destructive host actions remain deferred.

## Architecture

`packaging/app/` will be a SwiftPM package with three focused products.
`OrchardServiceLifecycle` owns path resolution, plans, transactions, rollback, retention, and status inspection.
`orchard-service` exposes the stable lifecycle CLI.
`Orchard` is the real app entry point and locates the embedded lifecycle executable and payload without duplicating lifecycle logic.

The assembled bundle has this shape:

```text
Orchard.app/
  Contents/
    Info.plist
    MacOS/Orchard
    Helpers/orchard-service
    Resources/payload/
      releases/
      native/
      bin/
      launchd/
      manifest.json
```

The first app bundle carries the same controller, node-agent, CLI, wrapper, and launchd inputs used by PKG staging.
Managed Postgres and the tray LaunchAgent remain excluded.

## Lifecycle Interface

The public command interface is:

```text
orchard-service install --role all|controller|node-agent [--root PATH] [--dry-run]
orchard-service update --role all|controller|node-agent [--root PATH] [--dry-run]
orchard-service uninstall [--root PATH] [--dry-run]
orchard-service status [--root PATH]
```

`--root /` mutations require effective user id 0.
A non-system root relocates every installed path and uses a deterministic launchd-state file instead of the host `launchctl` domain.
`--dry-run` emits a stable ordered plan without mutation and does not require root.
Failure injection is compiled for tests and accepted only for a non-system root.

Role values and installed paths are shared packaging contracts.
The app lifecycle honors the existing request-marker, persisted-marker, and default-`all` vocabulary so app and PKG artifacts remain compatible.
This first change does not rewrite the mature PKG preinstall and postinstall scripts around the new engine.
Cross-path contract tests prevent role, path, plist, and retention policy drift.

## Transaction And Rollback

Install and update use a lock plus a transaction directory under Orchard support state.
The engine preflights the payload and target before stopping any service.
It snapshots app-owned payload files, path links, launchd plists, the role marker, and prior simulated or real launchd loaded state.
It stages replacements, stops only affected services, atomically swaps app-owned paths, writes the role marker last, and restores the previously loaded in-role services.

A failure after mutation begins restores the prior payload, links, plists, role marker, and loaded-service state.
The failed transaction remains diagnosable without exposing secrets, and a later invocation can clean stale transaction metadata safely.
Operator-owned `config`, `data`, `models`, `bundles`, `logs`, and support-bundle contents are never replaced during install or update.

Default uninstall removes app-owned payloads, launchd plists, owned command links, install markers, and transient transaction metadata.
It retains `config`, `data`, `models`, `bundles`, `logs`, and operator-created support contents.
This slice does not add a purge option.
Complete existing TLS state is preserved.
Partial TLS state fails preflight, and the app lifecycle neither generates nor trusts production TLS material and never mutates system trust stores.
System-root install, update, and uninstall refuse to proceed while the `com.orchard.pkg` receipt exists, which avoids a stale-receipt takeover in this first slice.

## Signing And Amore Boundary

Signing order is nested libraries, nested executables with their existing entitlement class, app helper executables, the main app executable, and the outer app bundle seal.
Verification checks each Mach-O signature plus the final strict app-bundle signature.

The signing manifest records each signed path, SHA-256, CDHash, Team ID when present, hardened-runtime flags, and a canonical entitlement digest.
The DMG handoff runs against a disposable app copy.
It creates a local DMG through `amore create-dmg --skip-notarization`, mounts the result read-only, verifies the mounted app, and generates an after-manifest.
Nested code and entitlement records must match exactly.
Any undocumented nested re-signing or entitlement mutation fails closed.
The full `amore release` path remains outside this credential-free slice.
The integration feature-detects the required Amore CLI surface because the Homebrew cask auto-updates and public documentation can lag the installed CLI.

## Error Handling

CLI usage errors use stable non-zero exit codes and print no secrets.
Preflight failures mutate nothing.
Commit-phase failures trigger rollback before returning failure.
Rollback failure is reported distinctly and preserves the transaction directory for operator recovery.
System-root commands refuse to run without root, while status and dry-run remain non-mutating.
Status reports the selected role, app-owned installation state, retained-state roots, launchd state, and any blocking PKG receipt without changing them.

## Testing Strategy

Each behavior is implemented with one public-interface red-green cycle.
Swift unit tests cover plan and transaction state where a focused pure test adds value.
Integration tests invoke the built `orchard-service` executable against temporary roots and assert filesystem, role, launchd-state, rollback, and retention outcomes.
Packaging tests assemble a real app, inspect `Info.plist` and Mach-O entry points, use fake signing tools for deterministic ordering assertions, and use local ad hoc signing for credential-free bundle verification.
The local Amore smoke verifies actual DMG assembly and mounting when Amore is installed, while the deterministic test lane uses a fake Amore command and fixture DMG boundary.

## Migration And Compatibility

PKG remains supported and unchanged as an operator-driven, offline, and compatibility installer.
The app and PKG share source payload inputs and contract tests, not lifecycle implementation, until app behavior proves parity.
The real two-Mac app install plus MLX generation smoke becomes eligible only after the app path passes sandboxed lifecycle, rollback, signature preservation, and mounted-DMG validation, an approved Developer ID identity and notary profile produce a signed, notarized, stapled DMG that passes Gatekeeper, and Najib explicitly authorizes sudo or Touch ID root installation on both Macs.
At that point, the smoke SHALL exercise app-owned install, update, and uninstall parity before MLX generation; the parallel PKG smoke remains separately available under the same explicit root-authorization gate.
The documented system invocation is `sudo /Applications/Orchard.app/Contents/Helpers/orchard-service <operation>` until a separately approved native authorization UI or privileged-helper protocol exists.

## Durable Decision

The DMG becomes app-primary and PKG remains a separately distributed compatibility artifact.
This resolves the open product-shape question in `relax-enterprise-deployment-requirements` without changing its completed scope.
Amore is the current outer DMG and publication integration, while Orchard retains app assembly, nested signing, and verification authority.
