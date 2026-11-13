## Why

The tokenizer's sandbox should expose only the dictionary construction operations
and public namespace state required by chat templates. Its default Jinja globals
currently expose a broader surface than those rendering operations need.

## What Changes

- Replace the dictionary global with a limited callable that preserves ordinary
  construction and `fromkeys`.
- Reject underscore-prefixed namespace names at construction and assignment.
- Preserve marker provenance, existing attribute-read restrictions, ordinary
  mapping keys, and qualified template output.

## Impact

SPEC.md §3.5 gains a narrow chat-template global restriction. The tokenizer
implementation and regression tests change; no public API, dependency, Python
pin, model admission, qualification authority, or template-trust policy changes.
