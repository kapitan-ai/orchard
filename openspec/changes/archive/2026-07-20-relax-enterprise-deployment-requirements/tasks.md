## 1. Contract Updates

- [x] 1.1 Update SPEC.md §11 to remove MDM/Jamf and enterprise managed-device deployment as required v1 packaging behavior.
- [x] 1.2 Keep PKG requirements for privileged local installation, launchd service installation, role selection, upgrades, offline transfer, and manual `installer` use.
- [x] 1.3 Update milestone language so packaging readiness does not depend on Jamf, MDM, or enterprise deployment automation.

## 2. Documentation Updates

- [x] 2.1 Update packaging runbooks to remove current Jamf and MDM deployment guidance.
- [x] 2.2 Reframe private Homebrew cask guidance as optional future or convenience material if retained.
- [x] 2.3 Remove managed-device-specific filename or automation rationale from packaging docs unless it remains accurate without MDM support.
- [x] 2.4 Preserve warnings that packages, casks, scripts, and logs must not embed license keys, customer identifiers, DSNs, TLS material, or activation secrets.

## 3. Verification

- [x] 3.1 Search SPEC.md, docs, packaging, and OpenSpec materials for stale MDM/Jamf current-requirement language.
- [x] 3.2 Run strict OpenSpec validation for this change.
- [x] 3.3 Confirm no generated main specs were synced or archived in this pass; placeholder prose review remains required when syncing or archiving.
