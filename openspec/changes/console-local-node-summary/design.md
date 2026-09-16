## Context

The Node Join identity store already owns registered Node identity under an atomic `current` generation pointer. The legacy `data/node-id` file can differ from the enrolled certificate identity and must not become Console authority. Controller and Node services have separate environments even on an all-in-one host.

## Decision

The installation declares co-location through `ORCHARD_LOCAL_NODE_IDENTITY_ROOT` in Controller configuration. `orchardctl env init --service all` emits the standard local Node identity root for newly generated Controller configuration; Controller-only generation leaves it unset. Existing environment files retain their existing non-overwrite behavior. Custom Node identity roots require an explicit matching Controller setting.

The existing generation store remains the sole identity source. A shared read-only reader validates private directories/files, canonical generation identity and registered metadata, returning only Node ID, enrollment ID and certificate identifier. It reads no private key and never creates files. Missing, malformed, insecure, prepared, rotated-inconsistently or unreadable custody fails closed. Local configuration is an installation assertion, not remote attestation; host administrators remain its authority.

Console joins this identity to inventory and a target produced by trusted inventory, matching Node ID, enrollment and certificate identity. Current successful target metadata must match the Node ID. A claimed metadata ID, static target or matching hostname alone is insufficient. Existing StatusBuilder freshness and Node health remain authoritative; a stale heartbeat or failed current probe cannot display the positive headline. Prior successful heartbeat time remains visible, but current model status is unknown when the current target fails.

The association confers no enrollment, admission, scheduling, authorization or readiness. Controller-only/unconfigured installations do not gain a guessed local Node. No filesystem path or certificate material is rendered or logged by the summary.

## Validation and rollout

Use asymmetric identities, missing trust, mismatched certificate, malformed custody, stale heartbeat and failed current probe regression tests. Render healthy, stale, unavailable and unknown summary states. Portable CLI environment tests exercise generation without real service changes. macOS installed-service custody and startup remain a release gate; no claim of real-Mac acceptance is made from Linux tests.
