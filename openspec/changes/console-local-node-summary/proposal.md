## Why

All-in-one operators need to identify the Node on the Controller host without mistaking a reachable remote target, empty Inventory, or an old observation for a healthy local Node.

## What Changes

- Let all-in-one installation configuration explicitly select the existing registered Node identity store for a read-only Console association.
- Read only the current generation's non-secret metadata; never mint a second Node identity or load private keys into Console.
- Match the association to trusted inventory and the exact Runtime target before presenting current health.
- Add a local Node summary to Nodes Inventory, retaining unknown, stale and unavailable evidence separately from model serving.

## Capabilities

### New Capabilities

- `console-local-node`: Installation-owned local Node association and evidence-based Console summary.

### Modified Capabilities

None.

## Impact

SPEC section 4.5 gains a display-only local association contract. Installation environment generation, shared identity metadata reading, Console projection and tests change. No schema migration, scheduler, admission, trust grant, health threshold or real installation mutation is included.
