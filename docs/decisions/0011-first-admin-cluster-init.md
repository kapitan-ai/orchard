# ADR: First cluster-admin credential is minted by local `orchardctl cluster init`

## Status

Accepted. Implementation closes GitHub issue #75.
Refined by ADR 0014, which owns the cluster-init-only protected One-time Secret Output profile and its two commit points.

## Context

ADR 0004 defines the Admin API credential shape (a service-account-owned API Token whose enabled API Client holds a cluster-scoped `admin` RoleBinding) but explicitly deferred how the first such credential comes to exist.
Until a provisioning path lands, a fresh deployment has no supported way to mint the first cluster-admin credential, so the Admin API cannot be presented as operator-usable.
SPEC.md §11.9 already lists `orchardctl cluster init` as a required command, §11.7 places it immediately after PKG install in the offline flow, and the CLI carries a deferred stub for it.
SPEC.md §10.1 scopes Bootstrap Tokens to initial node join only, and `POST /admin/v1/bootstrap-tokens` requires the very admin credential being minted, so bootstrap tokens are not a first-admin path.
ADR 0006 already established the trust boundary a first credential needs: local `orchardctl` on the controller host executes with controller-runtime authority, without a bearer token, behind leader-only write gates and cluster-scoped audit.
ADR 0002 and SPEC.md §7.4.4 established the one-time-secret CLI output pattern (required operator-chosen `--output` path with preflight, hash-only persistence).

## Decision

Mint the first cluster-admin credential with `orchardctl cluster init` as a local, one-shot, audited controller-host operation.

Fixed contract points:

* One-shot by default: refuse with a stable `cluster_already_initialized` error when an enabled cluster-scoped `admin` RoleBinding already exists.
* Explicit break-glass: a `--force-new-admin` flag mints an additional admin credential, never resets, deletes, or mutates existing credentials, requires confirmation, and records a cluster-scoped audit event. This is the lost-all-tokens recovery path; local host access under ADR 0006 is the recovery authority.
* One-time secret output: required operator-chosen `--output` path; only the token hash and prefix persist. `SPEC.md` §11.9 and ADR 0014 own the publication protocol, its bounded fault model, and post-commit recovery behavior; the cluster-init profile does not modify the §7.4.4 bulk contract.
* Leader-only write gate: same boundary as node-admission and lifecycle CLI commands, so the command is Active/Standby-safe from day one.
* No default token expiry: rotation is encouraged through post-setup output guidance (provision named admin API Clients, then revoke the bootstrap credential) rather than a forced expiry that could brick the admin path on an appliance. This follows the ADR 0002 precedent of encouraging, not requiring, expiry.
* Credential-only scope: TLS material remains provisioned separately (`orchardctl tls init` local-CA helper or operator-provided material per §11.4), and this slice ships CLI-only with any first-admin bootstrap UI deferred.

Alternatives rejected:

* Unauthenticated one-shot bootstrap API endpoint (Nomad `acl bootstrap` shape) — Nomad needs a network bootstrap because its CLI is a pure API client; `orchardctl` already runs in the controller runtime, so a network mint surface adds an unauthenticated endpoint, a fresh-install race window, and a reset procedure that requires local disk authority anyway, while buying nothing for a 1-4 node on-prem product.
* Installer/PKG-seeded credential — controller hosts require external Postgres configured after install, so `postinstall` generally has no database to mint into; §11.4 precedent says the installer never generates trust material; unattended installs would scatter root-owned secret files with no operator-chosen destination; seeded default admins are the documented anti-pattern (Grafana `admin/admin`, MinIO `minioadmin`).
* Environment-seeded admin at controller boot — long-lived plaintext secret in launchd env files against §10.2's discipline, with re-seeding ambiguity on every boot; only fits container-first products.

Prior art: kubeadm mints local-file cluster-admin authority at `kubeadm init` and keeps bootstrap tokens strictly node-join material; k3s uses a server-local node token; Nomad's one-shot `acl bootstrap` demonstrates the one-shot guard plus guarded reset; Vault's `operator init` root token comes with use-for-setup-then-revoke hardening guidance, which this decision adopts as output guidance.

## Consequences

The Admin API becomes operator-usable on fresh installs through a documented local ritual, and the offline flow in §11.7 becomes fully executable.
The implementation slice adds a governance bootstrap module (transactional guard, ADR 0004 binding shape, one-time secret emission, audit) and the real `cluster init` CLI command with stable human and JSON output, plus happy-path and failure-path tests including the one-shot guard race, non-leader refusal, and output preflight failure.
The one-shot guard must be transactionally race-safe (unique constraint or serializable guard query), because two concurrent inits on a fresh database must not both succeed silently.
Future Console or Admin API credential-management surfaces may graduate the break-glass path to a dedicated command; the `--force-new-admin` flag remains the minimal slice until then.

## SPEC.md impact

§11.9 gains the normative `orchardctl cluster init` first-admin contract (one-shot guard, recovery flag, one-time output, leader-only, audit, credential-only scope).
§10.1's node-join-only scoping of Bootstrap Tokens is unchanged and is now explicitly load-bearing for this decision.
The OpenSpec change `first-admin-cluster-init` carries the corresponding `api-client-provisioning` requirement delta.
