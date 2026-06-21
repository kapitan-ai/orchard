# orchard_tokenizer

S6 bootstrap scaffold for Orchard's exact prompt rendering and token counting helper.

## Entrypoints

- project script (run from `native/orchard_tokenizer/`): `mise exec -- uv run orchard-tokenizer`
- dev-only repo wrapper from the repo root: `mise exec -- native/orchard_tokenizer/bin/orchard-tokenizer`

See `../../docs/tooling.md` for the required mise and uv workflow.

## Current behavior

The CLI currently emits a structured JSON placeholder so the package, tests, and
entrypoint wiring exist before the real tokenizer implementation lands in R4.
