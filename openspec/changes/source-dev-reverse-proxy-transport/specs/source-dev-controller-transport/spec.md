## ADDED Requirements

### Requirement: Source Development Has Explicit Transport Selection

A source-dev Controller SHALL consume `ORCHARD_TRANSPORT_MODE` as its deployment transport declaration. An unset value SHALL select `plain_http_localhost`; the only additional supported source-dev value SHALL be `reverse_proxy`. This realizes the existing transport contract in `SPEC.md` §10.7 without changing readiness semantics.

#### Scenario: Default source development remains loopback HTTP

- **WHEN** a source-dev Controller starts without `ORCHARD_TRANSPORT_MODE`
- **THEN** it binds the local HTTP listener and reports transport mode `plain_http_localhost` as degraded for public HTTPS readiness

#### Scenario: Unsupported source-dev mode fails closed

- **WHEN** a source-dev Controller starts with `ORCHARD_TRANSPORT_MODE=direct_https` or any unknown value
- **THEN** configuration fails with an actionable error before the Endpoint starts

### Requirement: Source-Dev Reverse Proxy Uses the Shared Trust Contract

A source-dev Controller in `reverse_proxy` mode SHALL use the same backend listener, public HTTPS URL, origin, trusted-proxy CIDR, and forwarded-header validation contract as a release Controller. A non-loopback backend bind MUST require an explicit non-empty `ORCHARD_TRUSTED_PROXIES` allowlist.

#### Scenario: Loopback reverse proxy uses bounded defaults

- **WHEN** a source-dev Controller selects `reverse_proxy` without overriding its backend bind or trusted proxies
- **THEN** it binds the HTTP backend to loopback, trusts only loopback proxy CIDRs, and publishes an HTTPS public URL and origin

#### Scenario: Non-loopback reverse proxy requires explicit trust

- **WHEN** a source-dev Controller selects `reverse_proxy` with a non-loopback backend bind and no explicit trusted-proxy allowlist
- **THEN** configuration fails before the Endpoint starts

#### Scenario: Untrusted forwarded headers are rejected

- **WHEN** a source-dev reverse-proxy request arrives from outside the configured trusted-proxy CIDRs or carries an invalid forwarded-header set
- **THEN** Orchard strips the forwarded headers rather than rewriting request scheme, host, port, or client address

### Requirement: Readiness Uses Configured Transport Without an Override

Source development SHALL configure the existing `Orchard.API.Transport` authority. It MUST NOT add a source-dev readiness flag, health-route exception, or proxy-reachability assertion.

#### Scenario: Reverse-proxy declaration satisfies the HTTPS readiness check

- **WHEN** a source-dev Controller starts with a valid `reverse_proxy` configuration
- **THEN** `public_api_https_enabled` evaluates true through `Orchard.API.Transport`

#### Scenario: Plain HTTP remains degraded

- **WHEN** a source-dev Controller uses the default `plain_http_localhost` mode
- **THEN** `public_api_https_enabled` evaluates false through the same authority
