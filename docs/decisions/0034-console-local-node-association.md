# ADR 0034: Installation-owned local Node association

## Status

Accepted for implementation under the approved local-Node Console slice.

## Decision

Use the existing registered Node Join generation store, not the compatibility
`data/node-id` file and not a second identity record. The installation explicitly
selects that local store in Controller configuration using
`ORCHARD_LOCAL_NODE_IDENTITY_ROOT`. Newly generated all-in-one environments set
the standard store path; Controller-only environments do not. Existing files
are preserved. Custom Node store paths require matching explicit configuration.

Read only protected `current` and registered `metadata.json`, returning the Node,
enrollment and certificate identifiers. Do not read keys or emit paths or raw
metadata into Console. Validate the association against trusted inventory target
bindings and observed Node identity before displaying positive evidence.

The host administrator asserts co-location through installation configuration;
this is not hardware attestation. A remote hostname or a lone reachable target
cannot establish local identity. Missing or mismatched evidence remains unknown.

## Consequences

No new persistent identity, schema migration, trust grant or health semantics.
Re-enrollment and identity rotation follow the existing generation pointer and
fail closed until inventory matches. Stale heartbeat and current probe failure
remain distinct from the last successful observation and model-serving status.
Installed macOS custody and service startup must be verified before release;
portable tests do not constitute real-Mac acceptance.

## SPEC.md impact

Section 4.5 adds the display-only installation association and evidence contract.
