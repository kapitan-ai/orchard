## Status

Proposed under KAP-112. Owner acceptance of this contract is required before
implementation. A second owner gate must accept the exact clean implementation
commit/tree and executable mutation plan before model download, provider
activation, or inference.

## Why

KAP-110 proves Orchard's model-free source-development control path on Ubuntu.
The next bounded question is whether real direct-API and OpenCode requests can
traverse the same unmanaged development profile through Orchard's API,
scheduler, Runtime Endpoint, and Worker Runtime. Production Linux provider or
coding-agent qualification is neither necessary for that question nor implied
by its answer.

## What Changes

- Permit one separately authorized, disposable inference proof as an explicit
  exception to the model-free KAP-110 baseline.
- Pin one `kapitan` H100, cached vLLM image, Qwen model/tokenizer revision, one
  loopback provider port, concurrency one, and bounded resources.
- Require a 131,072-rendered-input OpenCode envelope plus a separately reserved
  8,192-token output budget, meaningful long-context semantics, and explicit
  compaction, overflow, parser, usage, latency, and resource evidence.
- Add short repair and long-context smokes using the pinned installed OpenCode
  host client with Orchard as its configured model API, independent fixture
  checks, owner-authorization evidence, and no client-confinement or
  qualification claim.
- Add only the thin development adapter and disposable setup needed to preserve
  Orchard's existing scheduling/runtime path.
- Record provider-custody, cancellation, capacity-release, security,
  reliability, and qualification shortcuts as unproven rather than inferring
  production evidence.
- Require complete cleanup and two owner decisions: contract acceptance before
  implementation, then exact source/run acceptance before download or
  activation.

## Capabilities

### Modified Capabilities

- `platform-profiles`: Allows one proof-only inference exception within the
  unmanaged Linux source-development workflow while preserving every support
  and production authority gate.

### Added Capabilities

- `linux-source-dev-inference-poc`: Defines the immutable tuple, adapter seam,
  direct-API and OpenCode evidence, stop conditions, and cleanup.

## Impact

The accepted implementation would touch only source-development Worker adapter,
fixture, and documentation surfaces. It would not change appliance, production
Node, admission, Peer Grant, systemd, cgroup, packaging, release, deployment,
publication, qualification, or support behavior.
