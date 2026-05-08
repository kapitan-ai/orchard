# Manifest Schema Contract Fixture

`v1.json` is a product-owned contract fixture for Orchard model-manifest schema behavior described by SPEC §6.4. The fixture is consumed by product tests to keep manifest parser, controller, and worker assumptions aligned without changing canonical bundle fixture manifests.

## Safe-tokenization incompatibility categories

The manifest verdict enum `safe_tokenization.incompatibility_reason.category` is jointly owned by:

- SPEC §6.4
- this manifest schema contract fixture
- Elixir manifest and safe-tokenization validators
- the Python tokenizer deterministic preflight contract
- the Python safe-segmented producer constants

`category_enums` records the full sorted manifest enum plus the sorted tokenizer/template subsets. Keeping `version` at `1` is intentional: this block is additive test-contract metadata for an enum already covered by SPEC §6.4, not a manifest format bump.

When adding, removing, or renaming one of these manifest category strings, update all of the following in the same product change:

1. SPEC §6.4
2. `category_enums` in `v1.json`
3. Elixir category-set accessors and their local validator constants
4. Python safe-segmented producer constants
5. Python `cli._DETERMINISTIC_PREFLIGHT_INCOMPATIBILITIES`
6. Elixir and Python contract tests

Helper-local diagnostics and outer error-envelope categories are not manifest verdict enum members and must remain disjoint from `safe_tokenization.incompatibility_reason.category`.
