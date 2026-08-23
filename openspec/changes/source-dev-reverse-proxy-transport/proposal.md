## Why

Source-development Controllers cannot declare the HTTPS reverse-proxy topology already supported by Orchard, so the shared readiness evaluator reports `public_api_https_enabled` as false even when an operator has placed a valid HTTPS proxy in front of the source checkout. This blocks the internal source-dev pilot from using readiness honestly and forces unsupported runtime configuration overrides.

## What Changes

- Allow a source-dev Controller to select `reverse_proxy` through the existing `ORCHARD_TRANSPORT_MODE` environment variable.
- Preserve `plain_http_localhost` as the source-dev default.
- Apply the existing bind-address, trusted-proxy, forwarded-header, public URL, and origin validation to source-dev reverse-proxy mode.
- Reject `direct_https` in source dev; direct certificate and HTTPS listener ownership remains release-only.
- Keep `Orchard.API.Transport` as the single readiness authority without adding a readiness override or source-dev-only health shim.
- Document and test the supported source-dev reverse-proxy deployment path.

No SPEC.md behavior impact. The change makes source development realize the existing reverse-proxy transport contract in `SPEC.md` §10.7 without changing public health semantics or the staged readiness predicate.

## Capabilities

### New Capabilities

- `source-dev-controller-transport`: Defines supported source-dev Controller transport selection and reverse-proxy validation.

### Modified Capabilities

None.

## Impact

- Source-dev and release runtime configuration for Controller transport parsing and trusted-proxy validation.
- Source-dev Endpoint listener, public URL, origin, and forwarded-header configuration.
- Readiness configuration regression tests and source-development operator documentation.
- No API, persistence, dependency, packaged transport, or public health response changes.
