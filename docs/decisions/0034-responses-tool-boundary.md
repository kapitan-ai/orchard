# ADR: Responses tool dialect and client execution boundary

## Status

Accepted for the Responses tool-calling implementation; delivery and live-client
proof remain separate validation gates.

## Context

SPEC.md §7.2.5 names Responses as the canonical API, but its original tool
implementation accepted nested Chat definitions and terminal-only call data.
Canonical Responses clients send flattened tools and typed tool history, and
consume per-call lifecycle events.

## Decision

Normalize flattened definitions and named choices in the Responses boundary,
before shared validation. Retain the existing nested form as a compatibility
extension, without changing Chat validation to infer dialects. Reject mixed and
unknown fields. Preserve `strict`, schema contents, call IDs, argument/result
bytes and input order. Keep `tool://` refs as an explicit extension resolved
before tokenization and dispatch. Existing capability admission remains required.

Emit the standard call lifecycle from buffered selected-attempt calls at successful
completion. This deliberately trades early argument streaming for fail-closed
publication: an interrupted attempt cannot hand an executable partial call to a
client. Public text remains streamed and occupies output index zero if present;
calls follow in first-observed order. Correlate lifecycle indices and IDs with
terminal output. A missing inference terminal event fails the stream.

Tool execution belongs to the client. This change adds no execution authority to
Controller, Node, Worker or provider and does not qualify a model or platform.

## Consequences

Standard clients no longer need a protocol translation relay for this subset.
Nested Responses users retain compatibility. Tool results require a preceding
call in explicit input history; server-side conversation lookup, reasoning items,
non-function tools and non-string results are not introduced.

## SPEC.md impact

Updates §7.2.5, superseding its prohibition on per-call Responses SSE lifecycle.
