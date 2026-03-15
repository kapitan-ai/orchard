# Code Quality Plugins

Orchard uses two Credo plugins to maintain code quality in an AI-assisted development workflow. Both integrate into `mix credo --strict` and run automatically as part of the standard quality gate.

## Why These Tools

AI coding agents produce functionally correct code that often carries subtle quality issues:

- **Narrator documentation** that restates function names instead of explaining behavior
- **Obvious comments** like `# Create a temp directory` above `File.mkdir_p!`
- **Step comments** (`# Step 1: ...`, `# Step 2: ...`) instead of well-named functions
- **Identity passthroughs** — wrapper functions that add no value
- **Copy-paste duplication** across modules with minor variable renames
- **Blanket rescues** that swallow errors

Built-in Credo and Dialyzer don't catch these patterns. ex_slop and ex_dna fill that gap.

## ex_slop — AI Code Pattern Detection

ex_slop provides 23 checks for code patterns commonly introduced by LLMs. Orchard enables 20 of them.

### Enabled Checks (20)

**Warnings** — likely bugs or bad practices:
- `BlanketRescue` — `rescue _ ->` without meaningful handling
- `RescueWithoutReraise` — catching and discarding errors silently

**Refactoring** — code that has a simpler idiomatic equivalent:
- `FilterNil`, `RejectNil` — use `Enum.reject/filter` with `is_nil/1`
- `ReduceAsMap` — `Enum.reduce` that should be `Enum.map`
- `MapIntoLiteral` — `Enum.into(%{})` instead of `Map.new`
- `IdentityPassthrough` — functions that just call another function
- `IdentityMap` — `Enum.map(list, & &1)` (no-op)
- `CaseTrueFalse` — `case x do true -> ... false -> ...` instead of `if`
- `TryRescueWithSafeAlternative` — try/rescue where a safe alternative exists
- `WithIdentityElse`, `WithIdentityDo` — `with` clauses that don't add value
- `SortThenReverse` — `Enum.sort |> Enum.reverse` instead of `:desc`
- `StringConcatInReduce` — string building via `<>` in reduce

**Readability** — documentation and comment quality:
- `NarratorDoc` — `@doc` that just restates the function name
- `DocFalseOnPublicFunction` — `@doc false` on public functions (document or make private)
- `BoilerplateDocParams` — `@doc` that lists parameters without explaining behavior
- `ObviousComment` — comments that restate the next line of code
- `StepComment` — `# Step N:` comments (extract into named functions)
- `NarratorComment` — inline comments that narrate rather than explain

### Skipped Checks (3)

| Check | Why Skipped |
|-------|-------------|
| `RepoAllThenFilter` | Ecto-specific query optimization — not the focus of this rollout |
| `QueryInEnumMap` | Ecto-specific N+1 detection — same rationale |
| `GenserverAsKvStore` | High false-positive risk in OTP-heavy codebase; reconsider later |

## ex_dna — AST-Level Duplication Detection

ex_dna detects code clones at the AST level, finding duplicates that text-based tools miss (renamed variables, reordered clauses, near-miss structures).

### Clone Types

| Type | What It Finds |
|------|---------------|
| Type I (exact) | Identical code blocks (modulo whitespace/comments) |
| Type II (renamed) | Same structure with different variable names or literals |
| Type III (near-miss) | Similar structure with minor edits (requires `min_similarity < 1.0`) |

### Current Tuning

```elixir
# .credo.exs
{ExDNA.Credo, min_mass: 80, excluded_macros: [:@, :schema, :pipe_through, :plug]}
```

| Parameter | Value | Rationale |
|-----------|-------|-----------|
| `min_mass` | 80 | Filters out small utility patterns and test scaffolding. Default (30) produces too much noise in a codebase with repetitive test setup and CLI command patterns. |
| `excluded_macros` | `[:@, :schema, :pipe_through, :plug]` | Module attributes, Ecto schemas, router pipelines, and plug declarations are intentionally repetitive. |
| `min_similarity` | 1.0 (default) | Only exact and renamed-variable clones. Type III (near-miss) is not enabled yet. |

### Standalone Usage

```bash
mix ex_dna --paths "apps/"     # scan all umbrella apps
mix ex_dna.explain N            # detailed breakdown of clone N
```

The Credo-integrated check runs automatically via `mix credo --strict`. Standalone `mix ex_dna` is useful for exploratory analysis before adjusting thresholds.

## Fix vs Suppress

When a plugin flags code, apply this decision tree:

### 1. Is it a real issue? → Fix it

Most findings are genuine. Common fixes:

| Finding | Fix |
|---------|-----|
| Obvious comment | Delete the comment |
| Step comment | Extract steps into well-named functions |
| `@doc false` on public function | Add a real `@doc` string, or make the function private |
| `case true/false` | Replace with `if`/`else` |
| Identity passthrough | Inline the call or remove the wrapper |
| Code duplication (mass ≥ 80) | Extract into a shared module (e.g., `Orchard.StructCasting`) |
| Blanket rescue | Rescue specific exceptions and handle or reraise |

### 2. Is it a false positive? → Suppress with rationale

Some comments explain *why*, not *what* — ex_slop's heuristics may flag them. Suppress narrowly:

```elixir
# credo:disable-for-next-line ExSlop.Check.Readability.ObviousComment
# Server ignored Range header — partial file is now corrupt, must restart.
File.rm(partial_path)
```

Or for multi-line blocks:

```elixir
# credo:disable-for-lines:3 ExSlop.Check.Readability.ObviousComment
# The server returned 200 instead of 206, meaning it ignored our Range
# header. The appended data is now garbage — delete and retry.
File.rm(partial_path)
```

### 3. Is it intentional duplication? → Use `@no_clone true`

For code that is deliberately similar (e.g., CLI command modules following the same pattern):

```elixir
@no_clone true
def run(args) do
  # intentionally follows the same structure as other commands
end
```

### What NOT to do

- ❌ Disable a check entirely because it found many issues — fix the issues
- ❌ Suppress without a rationale comment — future developers won't know why
- ❌ Raise `min_mass` just to hide a real duplicate — extract the shared code
- ❌ Add `ignore: ["test/**"]` globally — test duplication is often a sign of missing test helpers

## Evolving the Configuration

### Adding ex_slop Checks

The 3 skipped checks can be enabled when the codebase is ready:

1. Enable the check in `.credo.exs`
2. Run `mix credo --strict` and assess findings
3. Fix genuine issues, suppress false positives with rationale
4. Update this doc's "Skipped Checks" table

### Lowering ex_dna min_mass

Reducing `min_mass` surfaces smaller clones. Before lowering:

1. Run `mix ex_dna --paths "apps/" --min-mass <new_value>` to preview
2. Assess signal-to-noise ratio — are the new clones genuine shared logic or just similar test setup?
3. Fix the genuine ones, then update both `.credo.exs` and `.ex_dna.exs`
4. Update the tuning rationale table above

### Enabling Type III (Near-Miss) Detection

Set `min_similarity: 0.85` in `.credo.exs` to also find structurally similar (not identical) code. This is more aggressive — start with a higher `min_mass` (e.g., 120) when enabling.

## Technical Notes

### Compile-Order Workaround

`ExDNA.Credo` is conditionally compiled with `if Code.ensure_loaded?(Credo.Check)`. Since Hex strips dev-only deps from published packages, there's no compile-order guarantee between `credo` and `ex_dna`. The `.credo.exs` uses `requires` to force-load the integration module at runtime:

```elixir
requires: ["deps/ex_dna/lib/ex_dna/integrations/credo.ex"]
```

If you see `Ignoring an undefined check: ExDNA.Credo`, this workaround has been lost — restore the `requires` entry.

### Config Files

| File | Purpose |
|------|---------|
| `.credo.exs` | Credo config — all ex_slop checks + ExDNA.Credo integration |
| `.ex_dna.exs` | Standalone ex_dna tuning for `mix ex_dna` |
| `.gitignore` | Includes `.ex_dna_cache` |
