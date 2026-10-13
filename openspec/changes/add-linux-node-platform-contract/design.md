## Context

The portable Node Agent, Runtime Endpoint interface, Worker Runtime boundary,
Node trust model, and Linux portable validation already exist. The missing seam
is a qualified Linux Node host and distribution profile. Existing macOS
lifecycle code is app/launchd-specific and must not acquire Linux branches.

KAP-18 has not established that public terminal delivery, cancel acceptance, or
a zero gauge proves native cessation or capacity release. KAP-26 has not yet
landed Worker Unit and Resource Allocation generations. KAP-27 explicitly
cancels outbound sessions. The design therefore permits independent package,
inventory, security, and diagnostics work while fencing later custody and
provider activation.

## Goals / Non-Goals

**Goals:**

- Bound the first Linux Node candidate tightly enough for reproducible evidence.
- Preserve one portable Node Agent and provider-neutral capability contracts.
- Keep host observations separate from allocations, custody, and scheduling.
- Make duplicate ownership, stale generations, and mixed-version ambiguity fail closed.
- Support deterministic relocated-root tests before privileged host exercises.

**Non-Goals:**

- General Linux, arm64, non-systemd, musl, WSL, container-host, or rootless support.
- Outbound-only Node sessions or a second transport protocol.
- Kubernetes, production deployment, package publication, or scheduling activation.
- Provider-specific Node Agent code or blanket CUDA, ROCm, vLLM, or model support.
- Defining KAP-18 release semantics or KAP-26 durable resource accounting here.

## Decisions

### One narrow host tuple precedes a distro family

The initial tuple is Ubuntu Server 24.04 LTS, x86_64, glibc, systemd, and unified
cgroup v2. Exact lower bounds match the base release. Point-release kernel
advancement within the Ubuntu hardware-enablement line is allowed, but another
distribution, architecture, libc, or init system needs separate evidence.

This keeps the first package and lifecycle tests meaningful. Claiming generic
Debian compatibility from one Ubuntu host was rejected.

### Package lifecycle and runtime privilege are separate

Root owns installation, update, rollback, and removal. The service runs under a
dedicated non-login identity and receives only path and device access required
by a separately qualified runtime profile. It has no package mutation, sudo,
database, device reset, or device reconfiguration authority.

The package uses fixed FHS locations and supports a relocated root in tests.
Relocation changes every owned path and simulates service-manager effects; it
must never mutate the real host.

The package bundles its exact ERTS and OTP release runtime. OS-supplied
prerequisites are a closed, version-constrained machine-readable manifest that
online and air-gapped installation share. Depending on an undeclared host
Erlang installation or public download was rejected because clean-host evidence
would not be reproducible.

### systemd owns the Agent cgroup; Orchard owns identity

One systemd system unit supervises one Agent and its process cgroup. Orchard
retains a process-lifetime exclusive lock in the durable identity root, because
systemd unit state alone cannot prove that no competing process uses the same
identity. PID files and `/run` state are diagnostic only.

`KillMode=control-group` can prove that systemd requested group cessation and
observed the cgroup empty. It cannot by itself release an Orchard request slot,
Resource Allocation, or placement. Those remain fenced by KAP-18 and KAP-26.

### Existing private-network connectivity remains authoritative

Linux uses production BEAM TLS Distribution plus scoped Peer Grants and keeps
certificate-authenticated gRPC for the accepted control and compatibility
roles. Service restart may reconnect with bounded jittered backoff, but it must
revalidate current certificate, admission, grant, target, and generation state.
It does not replay ambiguous inference operations.

Outbound-only sessions were rejected because KAP-27 records that they are out
of scope. Reintroducing them requires a separate accepted requirement and
transport contract.

Production BEAM remains unavailable to the candidate until the exact immutable
package proves first-party authenticity, protected certificate and Peer Grant
custody, trusted names, restricted networking, systemd and identity-root host
controls, and the named macOS-Controller/Linux-Node acceptance profile.

### Inventory is typed evidence, never an allocation

The Linux capability provider reads bounded OS interfaces and optional vendor
tools. CPU, memory, disk, OS, kernel, and network data use provider-neutral
fields. Accelerator records include vendor, stable identifier, PCI topology,
driver/runtime observations, memory, and health evidence when available.
NVIDIA and AMD schemas share a neutral envelope but retain distinct evidence
provenance and qualification.

Missing tools, permission failures, malformed output, duplicates, or unstable
identities produce absent or invalid evidence. Discovery never binds a device,
starts a runtime, constructs a Worker Unit, or creates capacity.

### Reader-first compatibility precedes writers

Additive observation readers land before Linux writers. An older observation
that lacks Linux or resource fields remains decodable but cannot prove those
facts. Commands whose safe meaning depends on Worker Unit, allocation,
incarnation, residency, or control generation require explicit negotiated
support. A receiver that cannot preserve the complete target rejects the
command; it must not downgrade to Node/model targeting.

### Mixed-platform evidence must include the Linux Node

The first acceptance topology is `macos_controller_linux_node_model_free`: a
qualified macOS Controller `N` operates Linux Node candidate versions `N` and
`N-1`. It proves enrollment, admission, authenticated observation, exact
unit/resource targeting, cancellation, drain, Agent restart, orphan handling,
and peer isolation using model-free fixtures. Each host captures its own
evidence. Unavailable macOS evidence is an unmet gate, not permission to infer
cross-host behavior from kapitan.

## Risks / Trade-offs

- **The profile is too narrow.** Additional distributions can be qualified later without weakening this evidence.
- **systemd state is mistaken for Orchard authority.** Tests and diagnostics label cgroup/process facts as observations and preserve separate release gates.
- **Vendor discovery becomes provider policy.** The capability adapter emits normalized evidence only and has no runtime-start or allocation dependency.
- **Relocated-root tests overstate reboot coverage.** Real systemd and reboot acceptance remain explicit qualification gates.
- **Version skew silently drops targeting.** New writers require negotiated complete targeting and old receivers reject it.

## Migration Plan

The contract lands before behavior. Implementation proceeds in package,
inventory, security, diagnostics, model-free custody, mixed-platform, and
provider-pilot slices. Every slice remains default-off and additive. No existing
macOS profile or Linux Controller behavior changes.

Rollback removes the unactivated candidate implementation and leaves persisted
Node identity untouched. Once real package qualification begins, rollback must
use the sequential cordon/drain/stop/replace/reconcile sequence and keep the
Node unschedulable on uncertainty.

## Open Questions

- KAP-18 must settle native cessation and request-slot release before custody can release capacity.
- KAP-26 must land allocation and generation contracts before resource-bound operations can activate.
- Package signing, repository publication, and public support require separate release decisions.
