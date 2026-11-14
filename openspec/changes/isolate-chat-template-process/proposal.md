## Why

Third-party chat templates are executable input, not trusted configuration.
The request-time helper currently inherits the Controller's environment and
working directory, exposing credentials if the Jinja sandbox is bypassed.

## What Changes

- Share a hardened tokenizer helper launch across request-time rendering and
  safe-tokenization/tool-capability preflight, including request preparation,
  imports and resident-memory backfill. Retain the timeout and stdout cap.
- Preserve that working directory through the source wrapper's uv fallback.
- State the template-trust policy in SPEC.md §3.5, point to it from §6.4, and
  record the staged boundary and residual exposure in ADR 0045.

## Impact

This is separate from `harden-chat-template-globals`. It changes the Controller's
rendering and preflight launches, the tokenizer wrapper and tests. OS network/write
denial, broader resource limits and OS containment at every render site (including
CLI/dev harnesses) are follow-up work, not delivered guarantees. The boundary
limits inheritance only: template code that escapes the Jinja sandbox can still
read same-user files and process metadata, such as the Controller's environment.
No public API, model support claim or qualification gate changes.
