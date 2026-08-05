## Why

`SPEC.md` §11.4 and §13.4 and ADR 0017 establish the zero-overlap contract for managed Node Agent replacement.
Orchard.app and PKG both manage the same launchd service, installed state, and Node Identity Root, so active handover needs one shared exclusion and recovery contract.
Without that contract, outgoing and replacement Node Agent processes could overlap on identity-bearing state even though Controller `N` supports Node Agent versions `N` and `N-1`.
Apple Installer also separates package scripts from payload placement, so PKG needs inert staging before one continuously owned active handover.

## What Changes

- Define one canonical crash-released Managed Lifecycle Exclusion Boundary shared by owner-side Orchard.app, PKG, managed recovery, and Node Agent start and stop paths including `orchardctl stop`, and keep the child-side managed launch gate outside it so it never contends with its own start owner.
- Make Managed Node Agent Start Eligibility State the authoritative launch fence and launchd load state only operational control, so every supported stop lands back in `suppressed` and the routine stop-then-start cycle is defined.
- Define a start request per entry state: an attempt only from `suppressed`, idempotent success under `enabled` with one verified healthy exact instance, managed recovery normalization for every other `enabled` combination, and non-transferable `one_shot_pending` continuable only by the exact live recorded owner.
- Model launchd plist presence, launchd job load state, managed process presence, Managed Node Agent Start Eligibility State, and lock ownership as independent dimensions that are never inferred from one another.
- Require one privileged owner to retain the same kernel advisory lock continuously, without ownership transfer or descriptor inheritance, from durable suppression and immediate pre-`bootout` process observation through every captured-instance exit or proven absence, active mutation, start policy, and terminal reporting.
- Require distinct durable handover, recovery, and start-attempt evidence before protected mutation and terminal coherent marking only after the applicable verification without treating metadata as exclusion ownership.
- Require Node Agent-only protected start suppression beneath launchd `RunAtLoad` and `KeepAlive`, combining persistent launchd job-domain disablement with launch-gate denial, and leave other role-selected services to normal supported launchd start behavior.
- Require every managed start attempt to verify or establish an unloaded job with no managed Node Agent process while holding the lock, then use crash-invalid operation-bound single-consumer one-shot authorization for one explicit bootstrap, with durable enablement only after the intended instance is verified.
- Define the one-shot matching predicate in components the child gate can observe without the canonical lock — attempt identity, exact non-reusable owner process identity, per-bootstrap nonce, launchd label, expected generation and executable identity, eligibility generation, and claim state — plus an observably live recorded owner, so a mid-attempt owner death fails closed with no live actor to re-apply disablement.
- Require a claimed child to run provisional, cluster-identity-free and non-serving, watching its exact recorded owner instance until that owner atomically records terminal coherent evidence and `enabled` eligibility bound to it.
- Require PKG to stage one complete authenticated and signed generation in a unique immutable or equivalently identity-stable incoming namespace, fully revalidate it immediately before atomic activation, reject invalid or changed generations before active mutation, keep `preinstall` from stopping or mutating the active Node Agent installation, and have `postinstall` synchronously invoke the active handover owner.
- Preserve direct `/usr/sbin/installer` support without an external wrapper.
- Preserve manual `orchardctl start` after every successful PKG fresh install and upgrade, with every role-selected service left stopped and no PKG automatic start or prior-loaded-state restoration.
- Preserve Orchard.app's unconditional full rollback attempt after post-mutation failure and classify incomplete or unverifiable rollback as uncertain and stopped.
- Define managed recovery under the same exclusion boundary before a later start can be reauthorized.
- Define launchd relaunch prevention as verified job-domain control rather than protected plist mutation.
- Define the BEAM Peer Grant Store Lock as operation-scoped and distinct from lifecycle exclusion.
- Preserve Controller `N` and Node Agent `N-1` safety through managed shutdown rather than live coexistence.

## Capabilities

### New Capabilities

- `managed-node-agent-handover`: Defines immutable authenticated single-generation PKG staging, the single-owner exclusion boundary, suppression-before-capture ordering, durable operation evidence, crash-fenced start authorization, reboot-safe suppression, zero-overlap ordering, path-specific start policy, managed recovery, fail-closed behavior, and guarantee limits.

### Modified Capabilities

- `app-distribution-lifecycle`: Requires managed Orchard.app Node Agent lifecycle operations to use the shared handover contract while preserving unconditional rollback and prior-loaded-state restoration obligations.
- `packaging-deployment`: Requires stage-then-activate PKG Node Agent lifecycle operations to use the shared handover contract while preserving direct installer support, manual start, and non-transactional PKG failure semantics.

## Impact

- SPEC.md impact: this change updates §11.2, §11.4, and §13.4 with the orthogonal lifecycle state model, reboot-safe Node Agent start suppression through persistent launchd job-domain disablement, the owner-side and child-side split of the exclusion boundary, the lock-held managed stop protocol, per-entry-state start dispatch, the observable one-shot matching predicate and provisional child phase, authenticated single-generation PKG delivery, single-owner crash-released exclusion, pre-`bootout` process capture, required durable recovery evidence, verify-or-establish start preconditions, manual PKG start, unconditional Orchard.app rollback, managed recovery, and historical-version serialization.
- Domain impact: the glossary's Packaging, Trust, and Operations section defines Managed Lifecycle Exclusion Boundary, Inactive Incoming Staging Root, Managed Node Agent Start Eligibility State, One-shot Launch Authorization, Provisional Node Agent Instance, Managed Node Agent Recovery, BEAM Peer Grant Store Lock, and Node Identity Root Lease, and refines Managed Node Agent Handover, while Topology keeps Node Agent and Node Identity Root.
- Operator impact: `orchardctl stop` becomes an owner-side protocol path rather than a bare launchd unload, so it acquires the canonical lock and leaves the Node Agent durably suppressed.
- Decision impact: ADR 0017 records the accepted stage-then-activate and single-owner design and corrects ADR 0012 attribution.
- Packaging impact: implementation must move Installer-managed payload out of active paths, bind activation to one immutable or equivalently identity-stable unique staging generation, revalidate before activation, make `postinstall` invoke one privileged active handover owner, and keep `preinstall` non-disruptive.
- Availability impact: PKG staging does not interrupt the running Node Agent, active handover incurs a bounded interruption, and durable suppression plus crash-invalid one-shot authorization keeps successful PKG installs and uncertain start attempts stopped across reboot and launchd retries until verified enablement.
- Recovery impact: timeout, owner death, missing or incomplete evidence, and uncertain state require the applicable managed lifecycle to reestablish coherence under the shared exclusion boundary.
- Security impact: the handover protects identity-bearing Node state from concurrent managed process use without broadening the BEAM Peer Grant Store Lock into lifecycle ownership.
