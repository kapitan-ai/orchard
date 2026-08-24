# Orchard.app and DMG packaging

The DMG's primary interactive artifact is a verified `Orchard.app`.
The app owns the root-authorized service lifecycle and installs the shared distribution-neutral payload.

The first productization slice proves app assembly, install/update/uninstall behavior in a relocated root, inner-first signing, local Amore DMG assembly, mounted-app verification, and nested-signature preservation.
Sparkle, broad updater UX, managed-device deployment, and destructive host installation remain outside this slice.

## Assemble the app

Build the existing production payload without installing it:

```bash
mise exec -- ./scripts/build-payload.sh
```

Use the printed `PAYLOAD_ROOT` value with the app builder:

```bash
scripts/build-app.sh \
  --payload-root /path/to/staged/payload \
  --output /path/to/Orchard.app \
  --version 0.5.0 \
  --build <git-sha>
```

`Orchard.app` contains a native main executable, the native `orchard-service` lifecycle helper, the shared lifecycle contract, and the existing production payload.
The app consumes the same payload surface validated by `scripts/build-payload.sh`.

## Service lifecycle

The app delegates service operations to its bundle-relative helper.
System-root mutations require an effective user ID of zero and therefore use an explicit authorization boundary:

```bash
sudo /Applications/Orchard.app/Contents/Helpers/orchard-service \
  install \
  --role controller
```

Supported operations are `install`, `update`, `uninstall`, and `status`.
Supported roles are `all`, `controller`, and `node-agent`.
An explicit `--role` wins, followed by a trusted `.install-role.request`, the persisted `.install-role`, and finally the `all` default.

Install starts no services.
Update restores only services that were loaded before the transaction and remain selected by the new role.
Every mutation snapshots app-owned paths and launchd state before stopping services, then rolls back on a caught failure.
The next mutation recovers a transaction left by abrupt termination before applying new work.
An exclusive advisory lock prevents a second lifecycle process from treating an active transaction as stale.
Transaction setup writes a versioned phase journal before target mutation and accepts only known launchd labels during recovery.
Dry-run never acquires the mutation lock or performs recovery; it reports a pending recovery step in its plan instead.

The lifecycle owns `bin`, `native`, `releases`, `share`, the staged `support/openssl` runtime, its role and transaction markers, its role-selected LaunchDaemon plists, and only command links that point at Orchard's installed wrappers.
It retains `config`, `data`, `models`, `bundles`, `logs`, and operator-created support contents on uninstall.
Complete TLS state is preserved unchanged, partial TLS state fails preflight, and the app never generates certificates or mutates a trust store.
The legacy `com.orchard.pkg` receipt still blocks app-owned system install, update, and uninstall so the app cannot silently take ownership of a legacy installation.

Use `--root /absolute/temporary/root` for non-destructive lifecycle tests.
The helper rejects relative roots, canonicalizes root aliases, rejects symlinked managed ancestors, and will not replace foreign files at managed command-link paths.
The app assembler and lifecycle allow only manifest-listed relative payload symlinks whose resolved targets remain inside the payload tree.
The signing manifests record both symlink paths and targets so the mounted-DMG comparison detects retargeting.

## Signing

Credential-free local signing is explicit and preserves the same inner-first order used for release signing:

```bash
scripts/sign-app.sh --identity - /path/to/Orchard.app
scripts/verify-app-signing.sh \
  --ad-hoc \
  --manifest-output /path/to/signing-manifest.json \
  /path/to/Orchard.app
```

For release signing, pass a `Developer ID Application` identity.
Nested payload libraries and executables are signed before the lifecycle helper, main executable, and outer app bundle.
The scripts never use `codesign --deep`.
Verification requires strict signatures, hardened runtime, the expected identity, secure timestamps for Developer ID signatures, and a deterministic nested manifest.
It scans every Mach-O under `Orchard.app/Contents`, not only known payload directories, and compares each embedded entitlement dictionary against the exact `beam`, `python`, or `default` entitlement class.

## Amore DMG handoff

The local, credential-free pipeline verifies the input app, gives Amore a disposable copy, mounts the resulting DMG read-only, verifies the mounted app, and fails if any nested signature or entitlement manifest entry changed:

```bash
scripts/build-dmg.sh \
  --ad-hoc \
  --release-notes-file /path/to/release-notes.md \
  --input /path/to/Orchard.app \
  --output /path/to/Orchard.dmg
```

Amore's free local tier may watermark the DMG.
Orchard does not pass `--no-watermark`, because current Amore rejects that option when the account tier does not allow it.

The exact credential-gated notarization and draft publication plan can be inspected without using credentials or uploading:

```bash
scripts/build-dmg.sh \
  --identity 'Developer ID Application: Example, Inc. (TEAMID)' \
  --notary-profile orchard-notary \
  --publish-draft \
  --release-notes-file /path/to/release-notes.md \
  --dry-run \
  --input /path/to/Orchard.app \
  --output /path/to/Orchard.dmg
```

Remove `--dry-run` only on an approved release host with the Developer ID identity and notary profile already available.
The release path requires Amore's current `create-dmg`, `release`, `--output`, `--codesign-identity`, `--keychain-profile`, `--draft`, `--release-notes`, and `--format` capabilities.
After Amore notarizes and staples the DMG, Orchard validates the staple before optional draft publication.

The completed release distribution set keeps these files together:

- `Orchard.dmg`
- `Orchard.dmg.release-notes.md`
- `Orchard.dmg.sha256`
- `Orchard.dmg.before-signing-manifest.json`
- `Orchard.dmg.after-signing-manifest.json`
- `Orchard.dmg.amore-release.json` when draft publication is requested

Release notes and verification metadata are sidecars instead of files injected into the image.
Amore owns final image assembly and notarization, so rewriting its DMG afterward would invalidate the outer distribution trust boundary.
Developer ID mode therefore requires `--release-notes-file`; the ad hoc local smoke accepts it but does not require it.

Once mounted-app verification succeeds — and, in Developer ID mode, the staple validates — Orchard retains the DMG and its sidecars even if a later checksum-write or draft-publication step fails.
A failure before that verification point removes the partial DMG and sidecar outputs.

## Validation

Run the Swift and integration workflow documented in `AGENTS.md` and `docs/tooling.md`.
Use `ORCHARD_TEST_REAL_AMORE=1 scripts/test-build-dmg.sh` for the local installed-Amore smoke without credentials or upload.
Run `spctl` and stapler validation only against a real Developer ID signed and notarized artifact.
