## Why

Orchard can verify a signed macOS app and can stop a source-development Node Agent with exact process custody, but it does not have one supported contract for changing a dedicated managed Apple Silicon macOS Node from controlled source-built bytes to Orchard-signed prebuilt bytes.
The first design attempted to admit both transition directions, legacy adoption, multiple builder trust paths, and a broad retained-state compatibility model.
Independent review found that those promises exceeded the smallest transition that Orchard can make precise against its current app lifecycle, Controller state machine, signing pipeline, and release-governance contract.

This revision defines one intentionally narrow v1.
It starts from an already managed `exact_ref_source_build` baseline created in a verifier-controlled isolated build environment, activates one `orchard_signed_prebuilt` generation on a dedicated Node-only host, and permits rollback only to that exact verified baseline.

## What Changes

- Reserve the `managed_apple_silicon_macos_node` identifier and define its experimental transition contract for a dedicated Apple Silicon macOS Node host that runs no Controller role; this change alone does not create a supported or production-admittable profile.
- Define one initial transition direction from an already managed `exact_ref_source_build` baseline to an `orchard_signed_prebuilt` candidate.
- Exclude legacy installation adoption, reverse provenance transition, arbitrary source builds, and pretrusted local builders from v1.
- Compose a macOS arm64 Node Agent component built from the provider-neutral Node Agent core, a launchd host adapter, and an exact-pinned single-process MLX Worker Provider with no executable or provider overrides.
- Admit and qualify the pinned OTP runtime's exact closed ERTS support-process set, including OTP 29 `erl_child_setup`, while treating exact-pinned `epmd` as stable host infrastructure outside replaceable generations and denying both serving or credential authority.
- Require closed component manifests, a composition lock, purpose-bound verifier decisions, and Candidate Manifest evidence with an acyclic identity and signing order.
- Store each baseline and candidate as an immutable generation and select the active generation through one atomically replaced pointer.
- Keep one stable signed lifecycle and recovery bootstrap outside every replaceable generation and prohibit bootstrap replacement during the v1 transition.
- Require an authenticated, role-constrained privileged-helper protocol, durable general launch suppression, a closed execution-grant set, a closed local Worker Provider spawn gate, and exact registered-process exit before the active pointer changes.
- Require reserve-before-spawn Worker registration, a dedicated unprivileged Worker identity, and an authenticated per-start local channel bound to exact process and execution identities.
- Permit one operation-bound provisional start while general launch suppression remains durable, then open the incoming Worker spawn gate only for the exact enabled child while scheduler exclusion remains active and require registered Worker Runtime readiness before active eligibility.
- Define an explicit retained Node Identity Set under one frozen schema and prohibit executable, provider, or identity-path overrides.
- Add a durable Postgres-backed Controller transition generation whose creation is the allocation-issuance fence and whose helper-serialized durable local epoch closure is the final-acceptance fence, establishes scheduler exclusion before the existing `draining -> maintenance` sequence, and blocks generic resume, leader-race reactivation, heartbeat-driven eligibility, managed-target fallbacks, and scheduler selection until exact terminal evidence is committed.
- Separate verifier admission for assembly from authorization for activation and bind each decision to purpose, stage, Node, operation, Controller transition generation, target profile, Node subtree, composition, final mounted app, accepted Candidate Manifest, and mandatory DMG evidence.
- Require rollback to restore only the exact baseline pointer and use the same suppressed one-shot provisional-start protocol.
- Require every uncertain verification, custody, activation, start, Controller, or rollback outcome to remain stopped, launch-suppressed, and unschedulable.
- Require adversarial real-hardware qualification against an exact supported model and feature matrix before the profile may be described as supported.
- Preserve foreground `make dev`, current source-development lifecycle, and the existing generic Orchard.app and DMG contract outside this dedicated-host profile.
- Keep Amore publication, credentials, tags, releases, Linux, WSL, Windows, Intel macOS, Controller-bearing hosts, all-in-one hosts, native PKG, relaxed skew, zero-downtime activation, standalone component support, and subsequent managed upgrades outside this change.

## Capabilities

### New Capabilities

- `managed-node-composition`: Defines the closed dedicated-Node composition, verifier-controlled source baseline, signed-prebuilt candidate, purpose-bound verification, immutable generations, frozen retained identity, and evidence-bound support claim.

### Modified Capabilities

- `platform-profiles`: Adds the dedicated Apple Silicon macOS Node profile and excludes Controller-bearing and all-in-one hosts.
- `packaging-deployment`: Defines the signing and identity order from closed Node subtree through final app, Candidate Manifest, and DMG evidence.
- `app-distribution-lifecycle`: Defines immutable-generation activation, atomic pointer replacement, stable bootstrap custody, one-shot provisional start, exact-baseline rollback, and fail-closed recovery.
- `host-lifecycle-adapters`: Defines authenticated helper authority, durable launch suppression, reserve-before-spawn Worker custody, the Worker Provider spawn gate, authenticated local channels, the no-new-execution point, and exact registered-process evidence.
- `operator-command-authority`: Defines the durable Controller transition generation and the multi-step terminal-acceptance protocol.
- `scheduler`: Makes an active managed transition generation an authoritative scheduler exclusion and prevents leader or heartbeat races from reactivating the Node.
- `worker-runtime-providers`: Preserves Node Agent logical Worker lifecycle ownership while routing managed-profile OS spawn, durable registration, termination, and exact exit custody through the stable helper.
- `portability-validation`: Adds public-seam and adversarial real Apple Silicon proof for the single forward transition, exact-baseline rollback, and every fail-closed boundary.

## Impact

- SPEC.md impact: acceptance would refine §§1.4, 2.5, 4.1 through 4.4, 4.6.2, 4.9, 4.10, 5, 7.5, 11.2 through 11.4, and 13.4 to reserve one experimental dedicated Node-only transition profile, one source-baseline-to-signed-prebuilt transition, a single-process Worker Provider contract, immutable generations, coordinated terminal acceptance, and exact-baseline rollback without a production support claim.
- SPEC.md conflict resolution: for `managed_apple_silicon_macos_node` only, acceptance would supersede §4.6.2's Controller-local F11 prohibition and M7 deferral only to the extent required by the durable grant-ID and fence-epoch protocol, without authorizing a general crash-recoverable reservation ledger. It would also narrowly supersede the no-managed-handover statement in §11.4 and ADR 0027 only for this named dedicated-host profile and this single transition direction.
- SPEC.md preservation: native PKG remains removed, ordinary source development remains foreground and unmanaged, Controller-bearing and all-in-one hosts remain outside the managed profile, and other platform or provenance routes gain no support claim.
- Decision impact: revise proposed ADR 0030 to record the dedicated-host restriction, one-way v1 transition, stable bootstrap, immutable-generation pointer, Controller transition generation, and frozen identity set.
- Acceptance prerequisite: `product-versioning-release-governance` must be accepted first, or both changes must be accepted atomically, because this profile's activation authority depends on its Candidate Manifest and final-artifact sealing rules.
- Release-governance dependency: component and composition evidence feed the final app identity and Candidate Manifest owned by `product-versioning-release-governance`, and production activation consumes only that final sealed evidence.
- Signing dependency: nested generation code is signed before its closed manifest and composition identity are sealed, the app is signed and verified next, mandatory DMG assembly and mounted verification follow, and the Candidate Manifest is sealed only after all final artifacts are verified.
- Controller impact: a managed transition becomes a durable generation-scoped operation in Postgres rather than a host-local service restart or generic maintenance and resume sequence.
- Host impact: the current replace-in-place transaction and automatic loaded-service restoration cannot implement this protocol.
- Identity impact: one explicit Node Identity Set remains outside replaceable generations at one frozen schema, and v1 introduces no identity migration.
- Entry-state impact: no existing unmanaged or legacy installation can be adopted, and production entry into the required already managed baseline remains blocked on a separately accepted clean-host provisioning contract with a concrete operator journey.
- Lifecycle impact: production admission also remains blocked on accepted operator-visible managed status and repair surfaces, a safe managed decommission path, and an accepted next-update strategy; until then the profile identifier and durable admission marker are experimental only.
- Validation impact: real Apple Silicon adversarial qualification is a support gate, not optional evidence.
- Implementation impact: this package defines intent and acceptance only and makes no runtime, packaging, signing, publication, or release change.
