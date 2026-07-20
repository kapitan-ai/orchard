## Why

Orchard's current packaging contract still carries enterprise deployment requirements even though no current customer or evaluator has asked for MDM or Jamf support.
Dropping that requirement now keeps the distribution work focused on the actual v1 need: a reliable Mac installer for privileged local services and manual operator workflows.

## What Changes

- Remove MDM/Jamf deployment as a required v1 packaging behavior.
- Reframe PKG support around root-authorized local installation, launchd service installation, role selection, upgrades, offline transfer, and manual operator use.
- Keep unattended `installer -pkg ... -target /` support when it is useful for local automation and repeatable smoke testing.
- Treat Homebrew, Jamf, MDM, managed-device policy examples, and enterprise deployment polish as optional future distribution channels, not current product requirements.
- Preserve the existing split between generic installer artifacts and out-of-band license activation.
- Preserve the current installer safety contract: no production TLS material, trust-store mutation, admin credential seeding, or customer-specific activation material in the package.

## Capabilities

### New Capabilities

- `packaging-deployment`: Defines Orchard's current macOS installer and distribution requirements after removing MDM/Jamf as a required v1 channel.

### Modified Capabilities

- None.

## Impact

- SPEC.md impact: update §11 Packaging and Deployment and milestone language so MDM/Jamf are no longer required v1 behavior.
- Documentation impact: update packaging runbooks that currently present private Homebrew, Jamf, or MDM deployment as supported current paths.
- Script impact: likely none for this change, because the current PKG scripts can still support local `installer` flows.
- Test impact: update or remove tests only if any currently assert MDM/Jamf-specific behavior rather than generic PKG behavior.
