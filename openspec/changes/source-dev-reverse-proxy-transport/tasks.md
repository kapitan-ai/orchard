## 1. Shared Transport Configuration

- [ ] 1.1 Extract shared reverse-proxy mode, listener, public URL, origin, and trusted-proxy parsing without changing release behavior.
- [ ] 1.2 Configure source development to accept the default `plain_http_localhost` and opt-in `reverse_proxy` modes while rejecting `direct_https` and unknown values.

## 2. Contract Coverage and Documentation

- [ ] 2.1 Add regression tests for source-dev defaults, valid reverse-proxy configuration, readiness authority, invalid modes, and non-loopback trusted-proxy enforcement.
- [ ] 2.2 Document the supported source-dev reverse-proxy environment and operator verification path in `docs/local-dev.md`.

## 3. Validation

- [x] 3.1 Run strict validation for `source-dev-reverse-proxy-transport` and review all change artifacts for placeholder prose.
- [ ] 3.2 Run the applicable Elixir format, compile, Credo, Dialyzer, test, and coverage workflow from the umbrella root.
- [ ] 3.3 After future sync or archive, run repository-wide strict OpenSpec validation and review generated main-spec prose for placeholders.
