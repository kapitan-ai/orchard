## Context

Issue #193 exposes a contract split across the shared-cookie Source-dev BEAM operating model.
`Orchard.Config.SourceDevBeam` accepts any concrete IPv4-literal target and derives exact `/32` Runtime Endpoint guardrails, while `Orchard.Config.ControllerMembership` and `Orchard.RuntimeEndpoint.BeamNodeName.private_ipv4/2` accept only RFC1918 addresses plus optional loopback.
`docs/local-dev.md` currently describes both identities and targets as RFC1918-only even though the accepted Runtime Endpoints specification requires a Tailscale CGNAT target to pass.

RFC1918 classification is not a trust decision.
Tailscale uses shared CGNAT space, while an operator-defined trusted network may also use owned globally routable prefixes internally.
At the same time, accepting every public address by default would make the shared-cookie development path easier to expose accidentally.

## Goals / Non-Goals

**Goals:**

- Give every shared-cookie Source-dev BEAM identity and target one explicit IPv4 network policy.
- Accept RFC1918 and Tailscale CGNAT IPv4 literals without extra configuration.
- Support unusual trusted networks through deliberate additive CIDR configuration.
- Keep live Runtime Endpoint guardrails narrowed to exact configured target hosts.
- Produce path-specific errors that name accepted address classes.
- Preserve the stricter enrolled production and Peer Grant identity contracts.

**Non-Goals:**

- Redesigning enrolled production network policy, Node identity, Controller identity, or Peer Grant identity.
- Making Tailscale mandatory or adding a Tailscale dependency.
- Adding hostname resolution, including Tailscale MagicDNS, or IPv6 BEAM Distribution support.
- Changing shared-cookie, EPMD, certificate, or Peer Grant mechanics.

## Decisions

### Use a dedicated Source-dev address policy

The pure policy component will live in the `config/`-loaded Source-dev configuration surface so `config/dev.exs` can use it before compiled application modules are available.
It will own IPv4/CIDR parsing, built-in networks, additive networks, address classification, and stable rejection reasons.
Configuration entrypoints will resolve the environment setting once and pass plain policy data explicitly rather than reading environment variables inside domain validation.

`Orchard.Config.SourceDevBeam` will apply the policy to Controller and Node Agent node-name hosts and Runtime Endpoint target hosts.
The Node Agent runtime configuration branch will invoke this validation; `bin/lib/source-dev-beam.sh` will retain syntax and service-name preflight without duplicating the address-class policy.
The Source-dev Controller configuration path will pass the same plain policy data into `Orchard.Config.ControllerMembership` for the membership host only when Peer Grants are disabled.
The membership host must continue to equal the Controller node-name host in BEAM mode.
Default `ControllerMembership` behavior remains strict when no Source-dev policy is supplied, preventing enrolled production and Peer Grant paths from inheriting the expansion.

Alternative considered: extend `BeamNodeName.private_ipv4/2`.
Rejected because globally routable operator CIDRs are not private IPv4, and an option-threading mistake could relax Peer Grant validation.

Alternative considered: keep targets permissive and special-case membership.
Rejected because it preserves inconsistent rules and allows globally routable targets without deliberate opt-in.

### Define safe defaults and additive operator networks

The policy accepts RFC1918 and `100.64.0.0/10` remote hosts by default.
`127.0.0.1` remains valid for same-host development.
`ORCHARD_SOURCE_DEV_BEAM_ALLOWED_CIDRS` adds comma-separated IPv4 CIDRs and does not replace the defaults.
Explicit additions may include globally routable prefixes so operators using owned address space internally are not forced into RFC1918.
An unrestricted `/0` addition is rejected; other prefix widths remain an explicit operator trust decision because identities and targets are still named individually.

Any malformed CIDR segment aborts startup and names the offending setting and segment.
Malformed host IPv4 values, hostnames including Tailscale MagicDNS, IPv6, unspecified or wildcard addresses, multicast, and the limited-broadcast address are rejected even when an added CIDR would otherwise contain them.
An absent or blank additive setting is equivalent to no additions.

Alternative considered: accept only exact `/32` additions.
Rejected because the live Runtime Endpoint guardrail is already derived as an exact `/32` for each configured target, while policy CIDRs describe which operator network may supply identities and targets.

### Keep network authorization narrow at runtime

The policy CIDRs authorize configuration values; they do not become BEAM Runtime Endpoint connection guardrails.
The Controller continues deriving `allowed_cidrs` as unique `/32` entries from configured targets.
This prevents a broad operator policy CIDR from authorizing unconfigured peers.

### Separate Source-dev and Peer Grant errors

Source-dev rejection errors will name loopback for same-host development where applicable, RFC1918, Tailscale CGNAT `100.64.0.0/10`, and `ORCHARD_SOURCE_DEV_BEAM_ALLOWED_CIDRS`.
A globally routable address rejected only because it lacks explicit authorization will report that distinction.
Peer Grant and strict membership errors will name RFC1918 non-loopback rather than the ambiguous phrase `private IPv4`.

## Risks / Trade-offs

- [Operator authorizes a public prefix and exposes shared-cookie BEAM] -> Require explicit CIDR configuration, reject `/0`, emit a startup warning naming the EPMD and BEAM Distribution exposure, retain exact-target `/32` guardrails, and document that host firewalls or network ACLs must restrict those ports to configured peers.
- [Source-dev policy leaks into production or Peer Grant mode] -> Keep the policy in a separate component and pass it at the existing Source-dev membership call only when `peer_grants_enabled?` is false.
- [Configuration paths drift again] -> Exercise Controller membership, both split-role launch paths, target parsing, Runtime Endpoint guardrail derivation, and a live two-host Tailscale CGNAT connection against one boundary matrix.
- [CIDR terminology implies that the full prefix is admitted] -> Document and test that policy CIDRs authorize configuration only and live target guardrails remain exact `/32` values.

## Migration Plan

Existing RFC1918 and same-host configurations continue working without changes.
Tailscale CGNAT IPv4-literal configurations become valid without extra settings; Tailscale MagicDNS names remain unsupported.
Existing globally routable targets, which target parsing previously accepted without a class policy, must be covered by `ORCHARD_SOURCE_DEV_BEAM_ALLOWED_CIDRS`.
Each split-role host evaluates the policy needed for its own identity, while the Controller also evaluates every configured target; the CIDR lists need not be identical when those responsibilities differ.
Rollback removes the additive setting and restores the previous RFC1918-only Controller membership behavior; no persisted data migration is required.

## Open Questions

None.
