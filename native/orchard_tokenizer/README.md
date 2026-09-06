# orchard_tokenizer

Python helper package for Orchard prompt rendering, exact token counting, and
safe-tokenization support. The controller calls the bundled `orchard-tokenizer`
helper before scheduling, as required by `../../SPEC.md` §3.5.

## Entrypoints

- project script, from `native/orchard_tokenizer/`:
  `mise exec -- uv run orchard-tokenizer`
- dev-only repo wrapper, from the repo root:
  `mise exec -- native/orchard_tokenizer/bin/orchard-tokenizer`

## Current behavior

The package implements the tokenizer helper contract used by the controller,
including Hugging Face tokenizer JSON, SentencePiece tokenizer models,
chat-template rendering, tool-aware payload fields, token counting, and
safe-tokenization catalog/segmentation support. See package tests for the
validated surface.

## Validation

Contract-v3 segmented rendering decodes tool-call history argument JSON into objects before template rendering and caller-string tagging.
Nested argument keys and strings remain protected; invalid argument objects fail before dispatch.
Exactly empty strings need no markers, while whitespace-only strings retain the normal protection.
Legacy non-segmented rendering is unchanged.

To check a tool-capable model's exact tokenizer assets without loading weights, point `ORCHARD_TOOL_TEMPLATE_SMOKE_PATH` at a directory containing `tokenizer.json`, `tokenizer_config.json`, and `chat_template.jinja`:

```bash
ORCHARD_TOOL_TEMPLATE_SMOKE_PATH=/path/to/pinned/assets mise exec -- uv run --directory native/orchard_tokenizer pytest tests/test_tool_template_smoke.py
```

This checks preflight, a tool-enabled first turn, and a synthetic tool-result continuation with safe encoding of a control-token literal in an argument.
Record the immutable model revision and asset digests alongside the result.
Passing this check does not qualify model generation or any particular client.

From the repo root:

```bash
mise exec -- uv run --directory native/orchard_tokenizer ruff format
mise exec -- uv run --directory native/orchard_tokenizer ruff check
mise exec -- uv run --directory native/orchard_tokenizer pytest
mise exec -- uv run --directory native/orchard_tokenizer pytest --cov
```

See `../../docs/tooling.md` for the required mise and uv workflow.
