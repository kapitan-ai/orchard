# Manifest Schema Contract Fixture

`v1.json` is a product-owned contract fixture for Orchard model-manifest schema behavior described by SPEC §6.4. The fixture is consumed by product tests to keep manifest parser, controller, and worker assumptions aligned without changing canonical bundle fixture manifests.

`top_level_keys` is the closed set accepted by supported consumers.
`required_top_level_keys` and `optional_top_level_keys` partition that set.
`deprecated_top_level_keys` identifies accepted compatibility metadata that is not authoritative product state.
Top-level `sha256` is optional and deprecated because the Catalog's `models.artifact_sha256` is computed independently over the final stored Artifact Bundle.

## Safe-tokenization incompatibility categories

The manifest verdict enum `safe_tokenization.incompatibility_reason.category` is jointly owned by:

- SPEC §6.4
- this manifest schema contract fixture
- Elixir manifest and safe-tokenization validators
- the Python tokenizer deterministic preflight contract
- the Python safe-segmented producer constants

`category_enums` records the full sorted manifest enum plus the sorted tokenizer/template subsets. `category_required_fields` records only the sorted required field names inside each `incompatibility_reason` reason object; it does not include envelope-level fields such as `template_compatible`, and it does not encode predicate semantics. Predicate semantics remain covered by the Elixir validator rule accessors and their contract tests.

Keeping `version` at `1` is intentional: these blocks are additive test-contract metadata for behavior already covered by SPEC §6.4, not a manifest format bump.

When adding, removing, or renaming one of these manifest category strings, update all of the following in the same product change:

1. SPEC §6.4
2. `category_enums` in `v1.json`
3. `category_required_fields` in `v1.json` when the reason-object field set changes
4. Elixir category-set accessors, `incompatibility_reason_rules/0` accessors, and their local validator constants
5. Python safe-segmented producer constants
6. Python `cli._DETERMINISTIC_PREFLIGHT_INCOMPATIBILITIES`
7. Elixir and Python contract tests

Helper-local diagnostics and outer error-envelope categories are not manifest verdict enum members and must remain disjoint from `safe_tokenization.incompatibility_reason.category`.
