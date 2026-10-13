## 1. Contract and documentation

- [x] 1.1 Define the unmanaged Linux source-development compatibility workflow in `SPEC.md` without changing supported platform status.
- [x] 1.2 Add the `platform-profiles` delta that keeps KAP-95/KAP-103 and all production authority gates separate.
- [x] 1.3 Document the Ubuntu developer-owned database, startup, model-free evidence, and cleanup boundaries in `docs/local-dev.md`.

## 2. Bounded compatibility smoke

- [x] 2.1 Record exact source, host, toolchain, PostgreSQL image, listener, process, and pre-existing-state identity before mutation.
- [x] 2.2 Run migrations and the existing all-in-one source command against disposable loopback-only PostgreSQL with the stub Worker backend and no model activation.
- [x] 2.3 Verify liveness, expected plaintext readiness, Console rendering, API authentication, loopback transport, empty trusted/admission inventory, and absence of Worker/provider/model/inference activity.
- [x] 2.4 Stop Orchard and PostgreSQL, remove only newly created state and credentials, preserve recorded pre-existing artifacts, and prove listener, container, volume, and Git cleanup.
- [x] 2.5 Record bounded independent review, exact evidence, and honest Linear disposition without claiming qualification or support.

## 3. Acceptance

- [x] 3.1 Record the Repository Owner's 2026-09-21 acceptance of exact KAP-110 commit `b18e648ed6e791b8a4a2d4f1e8a89c2ada67b57b` for the unsupported and unqualified model-free `kapitan` compatibility milestone without authorizing appliance qualification, production authority, inference, KAP-103, packaging, publication, deployment, release, or support.

## 4. Repeatable disposable database workflow

- [x] 4.1 Document the exact copy/paste KAP-110 smoke command without changing `make dev`.
- [x] 4.2 Add a digest-pinned, no-pull, loopback-only disposable PostgreSQL wrapper with separate init/client environments, private ephemeral credentials, collision checks, cleanup traps, and post-run absence proof.
- [x] 4.3 Add deterministic fake-engine tests for success, command failure cleanup, listener collision, container collision, and image drift without pulling or starting PostgreSQL.
- [x] 4.4 Re-run the bounded model-free smoke with the wrapper and record exact cleanup evidence.
- [x] 4.5 Obtain bounded independent review and record the KAP-111 disposition.
