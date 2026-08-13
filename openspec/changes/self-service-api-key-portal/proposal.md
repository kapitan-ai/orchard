## Why

App developers who call Orchard's Public Inference API need a long-lived bearer key without asking a cluster operator each time.
Today minting is operator-only: Console Organization detail, `orchardctl api-keys`, and `POST /admin/v1/api-keys`.
Those paths already satisfy `SPEC.md` §10.2.

A weaker Organization-scoped session is the missing minting gate.
It is not public signup, SSO, named users, or API Client minting.
Bulk API Client provisioning explicitly excluded human login and self-service token creation, so this change introduces a new capability rather than reusing Owner Contact or Team metadata as identity.

## What Changes

- Add a TLS-only Developer Portal at `/portal/:organization_slug` with its own layouts, pipeline, and LiveView session.
- Let an operator set, rotate, or clear one Organization portal password from Console Organization detail.
- Let a developer who presents that password mint, list, and revoke tenant-direct API Keys for that Organization only.
- Persist portal password hash, session epoch, portal session rows, login throttle fingerprints, and API key `issuance_surface`.
- Cap active portal-minted tenant-direct keys at 10. Operator mint stays uncapped and operator-only.
- Show the key secret once. After mint, show one activation curl or state that no callable model exists.
- Keep Public Inference Bearer format, Admin/Operator auth, and Console Basic Auth unchanged.

## Capabilities

### New Capabilities

- `developer-api-key-portal`: Organization-scoped self-service minting gate for tenant-direct API Keys.

### Modified Capabilities

- None.
  No accepted OpenSpec capability currently owns an Organization-scoped developer session.

## Impact

- SPEC.md impact: this change refines `SPEC.md` §2.3, §7.1, §7.4a, §8, §10.2, §10.8, and §10.9.
- Implementation impact: additive Postgres migration, `Orchard.Governance` password and portal-key facade, isolated `OrchardPortal` web namespace, and a Developer Portal card on `OrchardConsole.TenantDetailLive`.
- Security impact: slow password KDF, per-source login backoff, epoch-bound sessions, TLS-only availability, show-once secrets, and portal revoke limited to portal-minted keys.
- Non-impact: Public Inference `/v1/*`, Operator API, Admin API, Console Basic Auth, API Client provisioning, and Node TLS/BEAM credentials.

## Non-Goals

- No public signup, payment, named developer accounts, SSO, or `tenant_admin` Console login.
- No agent minting API or non-operator CLI mint.
- No API Client create, disable, or token mint from the portal.
- No quota, model-access, or Organization administration from the portal.
- No per-key rate limits.
- No change to the Public Inference key format or Bearer contract.
