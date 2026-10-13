## Status

Accepted by the Repository Owner on 2026-09-20 under KAP-96 at contract commit
`d323cc4d03fa3d21016f6aa9a3517ea71dcf0c5f`.
The Repository Owner accepted the KAP-97 normative reconciliation on 2026-09-20
at exact commit `ec21ab93729b9533a3993ed1908da8874f0df452`. The
owner-authorized review-history refactor maps that commit to
`4cfea2ea615cb26d7880390c596a3bc53349b212`; both have tree
`12ee4327a98abaf3bfbfe3c945331f0c435cdf48`.

KAP-97 acceptance does not satisfy KAP-82 and does not authorize KAP-98 or any
later implementation child. Source implementation and host mutation remain
held for separate owner authorization.

The Repository Owner accepted KAP-107 on 2026-09-20 at exact commit
`3b0c5ae359cbcf67da881cd29d65a7df92fe11d6`, amending the
near-term profile to exactly one source-development installation and one
Controller per host. KAP-96 and KAP-97 remain historical accepted decisions.
KAP-98 is superseded for this milestone, while its exact package commit
`b94f506a8d96bdbee9c62e3bb088666864f7e417`, artifact evidence, and
reproducibility findings remain deferred packaging/release inputs. Acceptance
grants no source implementation or host-mutation authority.

## Why

Orchard has separate portable Controller and experimental Ubuntu 24.04 Node
contracts but no accepted Linux distribution that safely composes Controller,
managed PostgreSQL, Node Agent, and Worker Runtime on one host. Treating
colocation as trust would weaken the same identity, admission, Runtime Endpoint,
Worker, lifecycle, and recovery boundaries needed for later multi-host use.

## What Changes

- Define the proposed `ubuntu_24_04_x86_64_single_host` distribution and
  acceptance profile over the exact existing Ubuntu 24.04 host tuple.
- Select one canonical root-owned source checkout, fixed configuration/state/
  runtime identities, one installation UUID, one exclusive lifecycle owner,
  distinct service identities, and default-off preparation.
- Fail closed before mutation or start for duplicate or ambiguous checkout,
  Controller, installation/state identity, lock, listener/port, EPMD/BEAM,
  PostgreSQL-cluster, or supervisor ownership.
- Define locally managed PostgreSQL 16 ownership, Unix-socket-only access,
  least-privilege roles, migration serialization, backup, restore, and disk-full
  behavior.
- Preserve ordinary enrollment, admission, Node and Controller Certificates,
  scoped Peer Grants, canonical private-address BEAM names, disconnect fences,
  and no-fallback Runtime Endpoint behavior on the same host.
- Define deterministic systemd ordering, cgroup-v2 control-plane reserves,
  durable lifecycle receipts, upgrade/rollback recovery, diagnostics, and
  expansion without identity cloning.
- Keep Worker execution and capacity disabled until the applicable KAP-18,
  KAP-26, and runtime-provider gates pass.

## Capabilities

### New Capabilities

- `ubuntu-single-host-composition`: Defines the role, authority, PostgreSQL,
  manifest, lifecycle, recovery, isolation, diagnostics, expansion, and
  qualification contract for the accepted, unimplemented source-development
  composition target.

### Modified Capabilities

- `platform-profiles`: Adds one accepted, unimplemented exact-host distribution and acceptance
  profile without broadening Linux or support claims.
- `packaging-deployment`: Records that the current Ubuntu profile is
  source-development-only, preserves fixed retained-state ownership, and
  requires a separately accepted fenced handoff before future packaging.
- `host-lifecycle-adapters`: Adds composed systemd ordering and durable phased
  recovery without claiming a whole-host transaction.
- `runtime-endpoints`: Requires the accepted production identity and Peer Grant
  path for the colocated Controller and Node and prohibits locality shortcuts.

## Impact

KAP-97 synchronizes the accepted contract into `SPEC.md` §§1.1, 1.4–1.5, 2,
4.1–4.9, 7.5, 10.5–10.7, 11–13, and Milestones 8–9 and into the main OpenSpec
capabilities. ADR 0037 records the accepted durable decision and
`docs/platforms/ubuntu-single-host.md` carries the reviewable operational
manifest and qualification plan.

The active change remains open for its implementation tasks. Its synchronized
requirements are represented as modifications of the accepted main capability
specs so a later implementation archive does not recreate duplicate
requirements or imply that implementation is complete now.

KAP-107 amends those synchronized requirements in place without erasing their
acceptance history. Source integrity uses exact Git commit/tree, clean-checkout,
dependency/toolchain lock, generated-output drift, and runtime receipt evidence.
Byte-for-byte BEAM or package reproducibility is deferred to future packaging
and release work unless those controls prove insufficient.

The KAP-82 credential contract, authenticated-connection amendment, and
predecessor synchronization are accepted and consistent with `SPEC.md`. Its
completed local certificate and Peer Grant implementation is sufficient for
separately authorized KAP-100 same-host source implementation. Real KAP-84
mixed-host qualification remains incomplete and stays required for later remote
topology and separation work; no issue is globally qualified by this bounded
dependency disposition.

This contract does not change current product behavior or support status. It
does not authorize implementation, host mutation, package work or publication,
PostgreSQL installation, provider/model activation, inference, deployment, or
KAP-27 outbound-session work.
