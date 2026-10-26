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
[ADR 0035: Experimental Linux Node candidate uses source development](0035-experimental-linux-node-source-development.md) is an accepted experimental candidate contract whose implementation and qualification remain pending.
[ADR 0036: Private-stage local-CA public artifact publication](0036-private-stage-local-ca-publication.md) defines how `orchardctl transport enable-local-https` publishes the local CA certificate and endpoint metadata.
[ADR 0037: Bounded Linux source-development inference experiment](0037-bounded-linux-source-development-inference-poc.md) proposes an independent default-off Worker experiment; historical proof is not current-main qualification or live execution authorization.
[ADR 0038: Stock MLX-LM with strict-prefix reuse is the runtime for the Qwen3.8 coding-agent tuple](0038-stock-mlx-strict-prefix-runtime-for-qwen38-coding-tuple.md) records an accepted runtime direction for one tuple; its qualification and `SPEC.md` promotion remain pending.
[ADR 0039: Worker crash recovery keeps its checkpoints in Postgres](0039-worker-crash-recovery-checkpoint-authority.md) records the accepted §12.2 checkpoint authority, supersedes the `define-worker-crash-recovery` contract, and allows in-process checkpoints for all-in-one source development.
