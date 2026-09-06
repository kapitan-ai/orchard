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
Null or omitted assistant content is accepted only with valid nonempty function-call history.
Text parts are concatenated before tagging, and trimming preserves provenance for every surviving caller byte.
Request-dependent failures do not create bundle-wide incompatibility cache entries.
Legacy non-segmented rendering is unchanged.

To check the pinned Qwen3-Coder qualification assets without loading weights, point `ORCHARD_TOOL_TEMPLATE_SMOKE_PATH` at a directory containing `tokenizer.json`, `tokenizer_config.json`, and `chat_template.jinja`:

```bash
ORCHARD_TOOL_TEMPLATE_SMOKE_PATH=/path/to/pinned/assets mise exec -- uv run --directory native/orchard_tokenizer pytest tests/test_tool_template_smoke.py
```

This checks preflight, a tool-enabled first turn, and a synthetic tool-result continuation with safe encoding of a control-token literal in an argument.
The test verifies the asset digests and complete production control-token catalog recorded in `tests/fixtures/qwen3_coder_30b_a3b_identity.json` for `mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit` revision `6e302ea604ad9ab206367e2c501d1571023e7b6d`.
Passing this check does not qualify model generation or any particular client.

From the repo root:

```bash
mise exec -- uv run --directory native/orchard_tokenizer ruff format
mise exec -- uv run --directory native/orchard_tokenizer ruff check
mise exec -- uv run --directory native/orchard_tokenizer pytest
mise exec -- uv run --directory native/orchard_tokenizer pytest --cov
```

See `../../docs/tooling.md` for the required mise and uv workflow.
