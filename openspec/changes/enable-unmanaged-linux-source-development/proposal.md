## Status

Accepted by the Repository Owner on 2026-09-21 at exact implementation and
smoke-record commit `b18e648ed6e791b8a4a2d4f1e8a89c2ada67b57b`.
Acceptance is limited to the unsupported and unqualified model-free workflow
demonstrated on `kapitan`. It does not authorize or prove the accepted Ubuntu
single-host appliance, production identity or admission, Peer Grants,
scheduling or capacity, PostgreSQL 16 appliance behavior, systemd or cgroup
enforcement, provider or model activation, inference, KAP-103, packaging,
publication, deployment, release, or support.

## Why

Orchard's portable applications and existing all-in-one source command can run
model-free on Ubuntu, but the current developer guide names only Apple Silicon
macOS while the accepted Ubuntu single-host contract describes a separate,
production-shaped source installation. A bounded contributor workflow must be
named without weakening or prematurely claiming that appliance contract.

## What Changes

- Define `linux_unmanaged_source_development_compatibility` as an unsupported,
  unqualified contributor workflow rather than a platform, distribution,
  runtime-provider, or acceptance profile.
- Permit the existing developer-owned all-in-one source command with pinned
  developer tooling, disposable development PostgreSQL, repo-local identity,
  loopback HTTP, and the loopback gRPC compatibility path.
- Require model-free validation to create no production Node inventory,
  admission, credentials, Peer Grants, scheduling or capacity authority,
  provider/model activation, or inference.
- Keep every KAP-95/KAP-103 singleton, custody, systemd/cgroup, managed
  credential, lifecycle, exact-host qualification, packaging, and support gate
  intact.

## Capabilities

### Modified Capabilities

- `platform-profiles`: Distinguishes the unmanaged Ubuntu contributor workflow
  from every qualified profile and from the accepted Ubuntu single-host
  composition.

## Impact

`SPEC.md` and `docs/local-dev.md` gain the explicit compatibility boundary and
model-free smoke expectations. The initial validation uses the existing
`make setup` and `make dev` command surfaces; no production runtime, admission,
packaging, host-service, provider, model, or inference behavior changes.
