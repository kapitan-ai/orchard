## Why

Third-party chat templates are executable input, not trusted configuration.
The request-time helper currently inherits the Controller's environment and
working directory, exposing credentials if the Jinja sandbox is bypassed.

## What Changes

- Launch the request-time tokenizer helper with an explicit minimal environment
  and a fresh private working directory, retaining the timeout and stdout cap.
- Preserve that working directory through the source wrapper's uv fallback.
- State the template-trust policy in SPEC.md §3.5, point to it from §6.4, and
  record the staged boundary and residual exposure in ADR 0045.

## Impact

This is separate from `harden-chat-template-globals`. It changes the Controller
request-time launch, the tokenizer wrapper and tests. Import/preflight launches
are inventoried but not isolated here. OS network/write denial, broader resource
limits and every-render-site containment are follow-up work, not delivered
guarantees. No public API, model support claim or qualification gate changes.
