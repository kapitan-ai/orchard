## Context

Release Controllers parse `ORCHARD_TRANSPORT_MODE` and configure listener, public URL, origin, and trusted-proxy behavior in `config/runtime.exs`. Source development instead hard-codes a loopback HTTP Endpoint in `config/dev.exs`, leaving `Orchard.API.Transport` at `plain_http_localhost` regardless of an operator-managed HTTPS proxy.

Readiness correctly consumes `Orchard.API.Transport.public_api_https_enabled?/0`; the defect is the missing source-dev deployment configuration, not the readiness evaluator. ADR 0016 forbids a second readiness truth or source-dev-only health override.

## Goals / Non-Goals

**Goals:**

- Let source-dev Controllers declare the existing reverse-proxy topology through deployment configuration.
- Keep release and source-dev reverse-proxy parsing and trusted-proxy validation aligned.
- Preserve fail-closed forwarded-header handling and actionable boot errors.
- Make readiness reflect the configured transport through its existing authority.

**Non-Goals:**

- Add source-dev direct HTTPS or certificate management.
- Observe or probe the external proxy from the Controller.
- Complete the broader `SPEC.md` §3.1 readiness aggregate.
- Change packaged transport behavior, public health bodies, or Portal transport enforcement.

## Decisions

### Source dev supports reverse proxy but not direct HTTPS

Source dev SHALL accept `plain_http_localhost` and `reverse_proxy`. The first remains the default. `direct_https` SHALL fail at configuration time with guidance that it is release-only.

This gives the pilot a supported HTTPS termination path without making certificate custody, generated CA metadata, or Cowboy TLS listener setup part of source development. Supporting all release modes was rejected because it widens this issue into TLS lifecycle and source-dev certificate management.

### Shared transport configuration owns common parsing

A configuration helper SHALL own source-dev mode selection and the reverse-proxy values shared with release configuration: bind IP, backend port, public host and port, trusted proxy CIDRs, public HTTPS URL, and origin checks. Both environments SHALL consume that helper for reverse-proxy configuration.

Duplicating the release parser in `config/dev.exs` was rejected because validation could drift. Moving the complete release TLS implementation was also rejected because only reverse-proxy behavior is shared.

### Existing runtime transport remains readiness authority

Source-dev configuration SHALL write the same `:orchard_controller, :transport_mode`, `:transport_degraded`, and Endpoint settings as the release path. `Orchard.API.Transport` and `TrustedForwardedHeaders` remain unchanged.

A readiness-specific flag was rejected because it would violate ADR 0016 and could report ready without applying the network trust boundary.

## Risks / Trade-offs

- **A declared proxy may be absent or broken** → Readiness continues to assert configured HTTPS topology rather than perform an external network probe, matching the existing release contract; authenticated inference remains the end-to-end availability check.
- **Source dev binds beyond loopback** → Non-loopback reverse-proxy binds require an explicit non-empty trusted-proxy allowlist, and forwarded headers remain stripped unless the peer and complete header set validate.
- **Shared helper changes release configuration** → Preserve existing release defaults and cover release/source-dev parity with focused configuration tests.
- **Direct HTTPS remains unavailable in source dev** → Operators needing direct certificate termination use a release build; source-dev operators terminate HTTPS in an external proxy.

## Migration Plan

No migration is required. Existing source-dev commands remain loopback HTTP by default. Operators opt in by setting the reverse-proxy environment variables before starting the Controller. Removing the opt-in restores the prior behavior.

## Open Questions

None.
