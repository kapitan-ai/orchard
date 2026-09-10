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
