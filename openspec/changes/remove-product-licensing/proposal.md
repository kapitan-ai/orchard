## Why

Orchard is being prepared for open-source distribution.
Product-license activation, entitlement enforcement, and license-derived feature gating are incompatible with that direction and currently create failure modes across Controller, Console, CLI, Node Agent, packaging, diagnostics, and telemetry.

## What Changes

- Remove Orchard product-license keys, activation, validation, status, enforcement, and feature gates.
- Remove license-derived fields from authenticated health, Sentry context, logs, and support/status output.
- Remove licensing UI and CLI commands, including first-run activation steps.
- Remove licensing configuration and packaging defaults.
- Preserve existing on-disk license bundles without reading, modifying, migrating, or deleting them.
- Tolerate and ignore legacy licensing environment variables during upgrade.
- Preserve the repository License section in `README.md`, copyright notices, third-party licenses, dependency notices, code-signing entitlements, and other legal or open-source attribution.

SPEC.md impact: §3.1 no longer permits licensing observations in Operator health, and §7.4a no longer needs a special prohibition on Developer Portal license state because Orchard has no product-license state to render.

## Capabilities

### New Capabilities

- `product-licensing-removal`: Defines Orchard's license-free product behavior and compatibility handling for legacy license artifacts and configuration.

### Modified Capabilities

- `packaging-deployment`: Removes license activation and activation secrets from the distribution lifecycle while preserving generic artifacts and legal attribution.

## Impact

- All useful-work paths become independent of product-license state.
- Existing installs stop reading or enforcing legacy license bundles immediately after upgrade.
- Existing license bundle files remain on disk for rollback safety and are not user data Orchard mutates during this change.
- Legacy licensing environment variables no longer affect startup and do not cause configuration errors.
- Operators lose license status, activation, and tracking surfaces permanently.
- Authentication, authorization, governance, quotas, accounting, billing that is not license-derived, and legal attribution remain unchanged.
