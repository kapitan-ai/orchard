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

From the repo root:

```bash
mise exec -- uv run --directory native/orchard_tokenizer ruff format
mise exec -- uv run --directory native/orchard_tokenizer ruff check
mise exec -- uv run --directory native/orchard_tokenizer pytest
mise exec -- uv run --directory native/orchard_tokenizer pytest --cov
```

See `../../docs/tooling.md` for the required mise and uv workflow.
