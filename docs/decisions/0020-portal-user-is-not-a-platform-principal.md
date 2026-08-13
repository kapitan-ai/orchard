# ADR: Portal User is a portal-scoped minting-gate identity

## Status

Accepted.

## Context

`SPEC.md` §7.4a currently describes a shared Organization portal password.
ADR 0002 refused first-class human users for bulk API Client provisioning and kept Owner Contact as metadata.
Developers still need isolated self-service keys.
A named portal login is required so one person cannot list or revoke another person's keys.

## Decision

Introduce **Portal User** as an interactive, Organization-scoped identity that may sign in only to the Developer Portal.
A Portal User may own portal-minted tenant-direct API Keys as minting-gate provenance.
Public Inference authentication stays `principal_type = tenant`.
`portal_user_id` is not consulted on the Bearer path.
A Portal User is not an Operator, Service Account, Owner Contact, or Tenant Admin.
Accounts are operator-invite only.
Invite URLs are shown once in Console and delivered out of band.
SMTP is not required.
Disable ends that Portal User's sessions.
It does not automatically revoke owned keys.
Operator Console remains the surface that can list and revoke those keys.

The shared Organization portal password is withdrawn as a login factor.
Do not run shared-password and named-login together.

## Consequences

ADR 0002 still holds for API Clients and bulk provisioning.
SPEC.md §2.3, §7.1, §7.4a, §8, §10.2, §10.8, and §10.9 must be updated.
Legacy unowned portal-minted keys remain valid Bearers and operator-visible only.

## SPEC.md impact

Update required in §2.3, §7.1, §7.4a, §8, §10.2, §10.8, and §10.9.
