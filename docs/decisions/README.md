# Decisions

This directory holds ADR-style records for durable Orchard implementation
decisions not already fixed by `SPEC.md`.

Use a decision record when a choice is architecture-significant, affects future
contributors, changes a boundary between components, or resolves ambiguity that
is not already answered by `SPEC.md`.

Decision records must be standalone:

- reference relevant `SPEC.md` sections when applicable;
- explain the decision and consequences;
- state whether `SPEC.md` needs an update;
- avoid private planning context, local paths, and tool session identifiers;
- avoid duplicating full normative contracts from `SPEC.md`.

Do not migrate historical coordination notes wholesale. Rewrite durable
conclusions as concise product-facing decision records.

Start from [`_template.md`](_template.md) when useful. Decisions already fixed by
`SPEC.md` do not need duplicate ADRs.

## Decision index

The current sequence includes [ADR 0030: Managed Node composition and activation](0030-managed-node-composition-activation.md), [ADR 0031: Workspace display and Access navigation](0031-workspace-display-and-access-navigation.md), and [ADR 0032: Source-only Apache publication](0032-source-only-apache-publication.md).
[ADR 0033: Named Console identities and shared management authorization](0033-cross-surface-authorization.md) is an accepted target contract whose implementation and cutover remain pending.
[ADR 0034: Installation-owned local Node association](0034-console-local-node-association.md) defines the display-only local Node association and evidence contract.
[ADR 0035: Experimental Linux Node candidate uses source development](0035-experimental-linux-node-source-development.md) is an accepted experimental candidate contract whose implementation and qualification remain pending.
[ADR 0036: Private-stage local-CA public artifact publication](0036-private-stage-local-ca-publication.md) defines how `orchardctl transport enable-local-https` publishes the local CA certificate and endpoint metadata.
[ADR 0037: Bounded Linux source-development inference experiment](0037-bounded-linux-source-development-inference-poc.md) proposes an independent default-off Worker experiment; historical proof is not current-main qualification or live execution authorization.
[ADR 0038: Stock MLX-LM with strict-prefix reuse is the runtime for the Qwen3.8 coding-agent tuple](0038-stock-mlx-strict-prefix-runtime-for-qwen38-coding-tuple.md) records an accepted runtime direction for one tuple; its qualification and `SPEC.md` promotion remain pending.
[ADR 0039: Worker crash recovery keeps its checkpoints in Postgres](0039-worker-crash-recovery-checkpoint-authority.md) records the accepted §12.2 checkpoint authority, supersedes the `define-worker-crash-recovery` contract, and allows in-process checkpoints for all-in-one source development.
[ADR 0040: Responses tool dialect and client execution boundary](0040-responses-tool-boundary.md), formerly ADR 0034 (responses-tool-boundary), defines client-owned tool execution and Responses tool-call publication.
[ADR 0041: CPU inference test lanes use llama.cpp and vLLM's CPU build](0041-cpu-inference-test-lanes.md), accepted on 2026-11-13, chooses default-off CPU-only Worker test lanes as implementation evidence under the `SPEC.md` §1.5 amendment; it grants no runtime-provider, platform or model support.
Numbers 0040 and 0041 were reserved by open pull requests when the reader proposal was drafted: Responses normalization and CPU inference test lanes, respectively. ADR 0042 skips those reservations to avoid another numbering collision.
[ADR 0042: A dedicated API Client can hold cluster-reader authority](0042-read-only-cluster-role.md) records the accepted, SPEC-reconciled target for a cluster-scoped, content-bounded read role with additive grants; implementation and activation remain pending shared-authorization prerequisites and reader verification.
[ADR 0043: Withdraw the Amore selection from the DMG distribution contract](0043-vendor-neutral-dmg-distribution.md): the decision accepted in ADR 0043 withdraws only the customer-delivery vendor selection while retaining GitHub as the release record, two-surface completion, and macOS trust gates.
[ADR 0044: Public release records and three release channels](0044-restricted-channel-release-records.md), accepted on 2026-11-13, removes the pilot Release Channel, requires record-only GitHub Releases and protects signed, notarized or restricted-channel (`trial`) bytes from general-audience-readable stores. It amends decision 1.4 and ADR 0043's pilot references while preserving its other outcomes and the distribution pause; remaining detail is deferred to delivery-surface selection, and its §11.3 sentence is held for release-governance task 2.1.
[ADR 0045: Controller template-renderer process boundary](0045-untrusted-chat-template-process.md) proposes the minimal renderer environment and private cwd under §3.5, inventories other render sites and distinguishes planned OS containment from delivered guarantees.
