## Context

Orchard currently implements a local dual-certificate product-license bundle.
The shared application validates and caches the bundle, the Controller gates product HTTP routes and Console actions, the Node Agent can block startup and runtime work, the CLI activates and inspects licenses, packaging defaults distributed channels to hard enforcement, and health, logs, Sentry, and Console surfaces report license state.

The only durable product-license record discovered in the current repository is the owner-only JSON bundle at the configured support-root path.
No licensing table, column, Ecto schema, or database migration exists.

## Goals / Non-Goals

**Goals:**

- Make all Orchard product behavior independent of license and entitlement state.
- Delete the product-licensing implementation and its callers rather than retaining dormant gates.
- Preserve upgrade and rollback safety for existing installs.
- Keep the change auditable across every affected public seam.
- Reconcile active OpenSpec work so future changes do not reintroduce licensing.

**Non-Goals:**

- Change authentication, authorization, governance, quotas, or unrelated billing/accounting.
- Delete legacy license bundles from operator machines.
- Remove legal attribution, third-party license material, or macOS code-signing entitlements.
- Add a replacement hosted entitlement or phone-home mechanism.

## Decisions

### Remove licensing as one reversible product slice

The Controller, Console, CLI, Node Agent, shared runtime, packaging, configuration, diagnostics, telemetry, docs, and tests change together.
Staging enforcement removal separately from UI and status removal would leave misleading activation guidance and hidden code paths that could be re-enabled accidentally.

The slice is reversible because it does not delete legacy bundle files or alter a database schema.
A code rollback can resume reading the existing bundle and legacy environment variables.

### Preserve legacy artifacts without a compatibility interface

Orchard does not read, validate, rewrite, migrate, or delete an existing `config/licensing/current.json` after this change.
Installers and uninstallers do not add a licensing-specific cleanup step.
The file remains inert operator-owned state.

Legacy `ORCHARD_LICENSE_*` values are tolerated because the runtime no longer parses them.
There is no deprecated status or activation command because such a command would preserve a misleading product interface.
`orchardctl license` follows ordinary unknown-command behavior.

### Fail open only with respect to the removed commercial gate

Removing licensing intentionally changes license failures from fail-closed to nonexistent.
It does not weaken API authentication, role authorization, tenant/model grants, quotas, Node admission, signed artifact verification, transport authentication, or governance policy.

### Remove license telemetry and identity

Operator health, logs, support bundles, and Sentry events no longer contain license state, license identifiers, machine-license hashes, licensee identity, or license tracking metadata.
Redaction rules may continue to recognize legacy license-shaped secrets only when they protect operators from accidental disclosure; those rules are security hygiene, not a licensing subsystem or product interface.

### Preserve legal and platform meanings of license and entitlement

Repository and dependency licenses remain unchanged.
macOS signing entitlements remain unchanged.
Text referring to third-party plan entitlements or unrelated external entitlements is outside the product-license subsystem unless it creates Orchard product gating.

## Risks / Trade-offs

- The blast radius spans every shipped Orchard role and packaging path.
- Removing gates could expose an unrelated authorization assumption if code incorrectly relied on license denial as defense in depth.
- Legacy automation invoking `orchardctl license` will fail after upgrade and must be removed.
- Leaving inert bundle files avoids destructive migration but retains sensitive historical material under its existing permissions until an operator deletes it.

These risks are addressed with public-seam tests, caller tracing, security review of preserved authorization paths, full quality gates, packaged-flow tests, RepoPrompt review, and No Mistakes review.

## Migration Plan

1. Update `SPEC.md` and affected active OpenSpec packages so product truth no longer anticipates licensing.
2. Add public behavior tests proving useful work, Console actions, first-run, and Node startup no longer depend on license state.
3. Remove the shared licensing modules and all enforcement/status callers.
4. Remove CLI, Console, diagnostics, telemetry, configuration, packaging, documentation, fixtures, and tests that exist only for product licensing.
5. Search the repository for residual product-license interfaces and trace ambiguous matches.
6. Validate OpenSpec, run the complete applicable Orchard quality workflow, run packaging-focused tests, and complete independent reviews.

## Rollback Plan

Revert the change and restore the prior configuration templates.
Because the migration leaves legacy bundle files untouched and makes no database changes, rollback does not require data restoration.
Operators that manually deleted a legacy bundle outside Orchard must reactivate only after rollback.
