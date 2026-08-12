## 1. Source-dev Address Policy

- [x] 1.1 Add boundary tests for RFC1918, CGNAT edges and adjacent addresses, custom CIDRs, `/0`, default-public rejection, loopback, malformed list segments, and invalid host classes.
- [x] 1.2 Implement the pure `config/`-loaded Source-dev IPv4/CIDR policy with RFC1918 and `100.64.0.0/10` defaults plus additive `ORCHARD_SOURCE_DEV_BEAM_ALLOWED_CIDRS` parsing.
- [x] 1.3 Add stable path-specific error formatting and globally routable exposure warnings that name accepted Source-dev and strict Peer Grant address classes.

## 2. Configuration Integration

- [x] 2.1 Apply the policy to Controller and Node Agent `ORCHARD_BEAM_NODE_NAME` validation and Runtime Endpoint target parsing, keeping shell preflight limited to syntax and service names.
- [x] 2.2 Pass plain policy data at the existing Source-dev Controller membership call only when Peer Grants are disabled, preserving strict default and Peer Grant behavior.
- [x] 2.3 Preserve exact `/32` Runtime Endpoint connection guardrails for every configured target, including targets authorized through broader operator CIDRs.
- [x] 2.4 Reconcile split-role launch and runtime configuration tests for Tailscale CGNAT IPv4 literals, MagicDNS rejection, custom-CIDR topologies, membership/name disagreement, and unchanged Peer Grant rejection.

## 3. Operator Contract

- [x] 3.1 Update `docs/local-dev.md` with zero-config Tailscale CGNAT IPv4 literals, explicit MagicDNS non-support, custom-CIDR migration, trusted-network warnings, EPMD and Distribution firewall obligations, and corrected troubleshooting guidance.
- [x] 3.2 Ensure configuration examples and errors distinguish shared-cookie Source-dev policy from enrolled production and Peer Grant identity policy.

## 4. Verification

- [x] 4.1 Run the focused Source-dev configuration, Controller membership, Runtime Endpoint guardrail, and split-role launch test slices.
- [x] 4.2 Run a real two-host Tailscale CGNAT smoke that establishes BEAM Distribution and completes a Runtime Endpoint status call, not only configuration admission.
- [x] 4.3 Run `mise exec -- mix format`, compile with warnings as errors, strict Credo, Dialyzer, the full test suite, and coverage.
- [ ] 4.4 Run strict OpenSpec change validation before implementation handoff and strict all-spec validation after accepted behavior is synced or archived.
- [ ] 4.5 After sync or archive, inspect generated main specs and remove placeholder prose such as `Purpose TBD`.
