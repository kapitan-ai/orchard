## Final Prompt
<taskname="Keygen test coverage"/>
<task>Add missing test coverage in `apps/orchard_shared/test/orchard/licensing_test.exs` for Keygen certificate format handling. Specifically: (1) add an `install_pair/2` success-path test using a Keygen-format bundle (`:keygen_checkout`), (2) add malformed Keygen envelope tests for `alg`/`sig` variants while preserving and confirming current missing/non-string `enc` coverage, and (3) add an install failure test proving the last known good bundle remains unchanged when installing a tampered Keygen bundle. Validate by running this test file and report total test count (expected to land around 39).</task>

<architecture>
- `Orchard.LicensingTest` is a single-file integration-style unit test module for `Orchard.Licensing.inspect_local/1`, `install_pair/2`, and summary/decision helpers.
- Test data is produced either from JSON fixtures or via in-file certificate builders:
  - `build_signed_bundle/6` generates paired license/machine certificates.
  - `sign_certificate/3` supports two envelope formats: `:orchard_canonical` and `:keygen_checkout`.
- Runtime behavior under test:
  - `Orchard.Licensing.install_pair/2` validates via `Orchard.Licensing.Validator.validate_pair/2`, then writes via `Orchard.Licensing.LocalStore.write/2` only if installable.
  - `Validator.extract_payload_and_signing_input/3` branches on envelope format:
    - canonical: `alg=ed25519`, `enc=base64`, `payload` present; signature over decoded payload bytes
    - Keygen checkout: `alg=base64+ed25519`, `enc` contains base64 payload; signature over `"<kind>/<enc>"`
</architecture>

<selected_context>
apps/orchard_shared/test/orchard/licensing_test.exs: Primary target file. Existing Keygen coverage currently lives in `describe "inspect_local/1"` (valid Keygen variants, tampered signature/enc, missing/non-string enc). `describe "install_pair/2"` currently covers canonical success + preservation on canonical tamper/write-failure but has no Keygen-specific install success/failure tests.
apps/orchard_shared/lib/orchard/licensing.ex: `install_pair/2`, `install_pair_with_config/2`, and `ensure_installable/1` define when writes happen and error propagation behavior used by preservation tests.
apps/orchard_shared/lib/orchard/licensing/validator.ex: Envelope parsing/signature validation rules, especially `extract_payload_and_signing_input/3`, `decode_signature_field/2`, and malformed error messages for invalid envelope shape/field types.
apps/orchard_shared/lib/orchard/licensing/local_store.ex: Atomic write semantics (`write/2`) that explain why failed validation must preserve prior bundle contents.
</selected_context>

<relationships>
- `Licensing.install_pair/2` -> `normalize_bundle_pair/2` -> `read_node_identity/2` -> `Validator.validate_pair/2` -> `claims_to_status/4` -> `ensure_installable/1` -> `LocalStore.write/2`.
- In tests, `build_signed_bundle/6` + `sign_certificate/3` generate both canonical and Keygen envelopes; tamper helpers mutate decoded envelope fields (`tamper_signature/1`, `tamper_enc/2`, `remove_enc/1`).
- Keygen-specific parsing path in validator is gated by `alg == "base64+ed25519"` and `enc` presence/type; malformed `alg`/`sig` scenarios should assert validator-derived state/message surfaces through `Licensing.inspect_local/1` or `install_pair/2`.
</relationships>

<ambiguities>
- Current file has explicit coverage for Keygen `enc` missing/non-string and signature tamper, but no explicit `alg`-variant malformed assertions yet.
- Current test count in `licensing_test.exs` is 34 (`test "` occurrences), so adding ~5 tests should land near the user’s expected ~39.
</ambiguities>

## Selection
- Files: 4 total (4 full)
- Total tokens: 14372 (Auto view)
- Token breakdown: full 14372

### Files
### Selected Files
/Users/najib/Hacks/orchard/
└── apps/
    └── orchard_shared/
        ├── lib/
        │   └── orchard/
        │       ├── licensing/
        │       │   ├── local_store.ex — 906 tokens (full)
        │       │   └── validator.ex — 3,444 tokens (full)
        │       └── licensing.ex — 2,605 tokens (full)
        └── test/
            └── orchard/
                └── licensing_test.exs — 7,417 tokens (full)


---

## Generated Plan

## Chat Send ✅
- **Chat**: `keygen-test-coverage-16466E` | **Mode**: plan

### Response
# 1. **Summary**

This is a targeted test-only change in `apps/orchard_shared/test/orchard/licensing_test.exs`, not a refactor: the production licensing pipeline already supports Keygen checkout envelopes, but the test matrix is missing (a) `install_pair/2` success coverage for a fully Keygen-formatted bundle, (b) malformed Keygen envelope coverage for `alg`/`sig` field variants, and (c) an `install_pair/2` preservation test proving a tampered Keygen bundle does not overwrite the last good on-disk bundle. Reuse the existing in-file certificate builders and mutation helpers, add only the minimal extra helpers needed for `alg`/`sig` mutations, keep the current `enc` missing/non-string tests intact, and validate by running this single test file; if exactly five tests are added, the file should report **39 tests** total.

# 2. **Current-state analysis**

## Relevant responsibilities and ownership

### `apps/orchard_shared/test/orchard/licensing_test.exs`
This is a single integration-style unit test module covering:

- `Orchard.Licensing.inspect_local/1`
- `Orchard.Licensing.install_pair/2`
- `Orchard.Licensing.health_summary/1`
- `Orchard.Licensing.startup_decision/2`

It already contains all required local test infrastructure:

- temp directory setup
- bundle file writing and reading helpers
- node identity writing
- synthetic certificate generation via:
  - `build_signed_bundle/6`
  - `sign_certificate/3`
- envelope mutation via:
  - `tamper_signature/1`
  - `tamper_enc/2`
  - `remove_enc/1`
  - `mutate_certificate_envelope/2`

It also already covers Keygen checkout behavior in `describe "inspect_local/1"` for:

- valid license certificate in Keygen format
- valid machine certificate in Keygen format
- tampered Keygen signature
- tampered Keygen `enc`
- missing Keygen `enc`
- non-string Keygen `enc`
- real captured Keygen bundle fixture

### `apps/orchard_shared/lib/orchard/licensing.ex`
`Orchard.Licensing` is the user-facing façade.

Key flows:

- `inspect_local/1`
  - `resolve_config/1`
  - `read_bundle/1`
  - `read_node_identity/2`
  - `Validator.validate_pair/2`
  - `claims_to_status/4`

- `install_pair/2`
  - `resolve_config/1`
  - `normalize_bundle_pair/2`
  - `read_node_identity/2`
  - `Validator.validate_pair/2`
  - `claims_to_status/4`
  - `ensure_installable/1`
  - `LocalStore.write/2`

Important constraint: `install_pair/2` only calls `LocalStore.write/2` after validation succeeds and status is `:valid`. Any validator error short-circuits before disk mutation.

### `apps/orchard_shared/lib/orchard/licensing/validator.ex`
This is the format-specific logic under test.

For each certificate:

1. `extract_signed_payload/2`
2. `decode_signed_envelope/3`
3. `extract_payload_and_signing_input/3`
4. `decode_signature_field/2`
5. signature verification
6. payload JSON decode
7. claims normalization

Supported envelope branches:

- **Orchard canonical**
  - `alg == "ed25519"`
  - `enc == "base64"`
  - `payload` present
  - signature over decoded payload bytes

- **Keygen checkout**
  - `alg == "base64+ed25519"`
  - `enc` present
  - signature over `"<kind>/<enc>"`

Malformed behavior relevant to requested tests:

- unsupported or inconsistent Keygen `alg` falls through to:
  - `{:error, {malformed_state, "certificate envelope format is invalid"}}`
- missing `sig` or non-binary `sig` both currently map to:
  - `{:error, {malformed_state, "certificate signature is missing"}}`

That last point matters: there is no distinct `"signature must be a string"` error today.

### `apps/orchard_shared/lib/orchard/licensing/local_store.ex`
`LocalStore.write/2` implements atomic write semantics:

- create temp file
- write contents
- `chmod 0600`
- rename into place

This is why the preservation tests are meaningful:

- validation failure means `LocalStore.write/2` is never reached
- write failure means temp file is cleaned up and existing file remains untouched

## End-to-end call chains

### Malformed Keygen envelope through `inspect_local/1`
Test-generated Keygen bundle  
→ `write_bundle!/2` persists JSON bundle  
→ `Licensing.inspect_local/1`  
→ `LocalStore.read/1` decodes JSON  
→ `NodeIdentityFile.read/1` loads local node id  
→ `Validator.validate_pair/2`  
→ `extract_payload_and_signing_input/3` or `decode_signature_field/2` fails  
→ error tuple `{state, message}`  
→ `Licensing.inspect_local_with_config/1` converts to `%Licensing{}`  
→ assertions inspect `state` and `message`

### Tampered Keygen install through `install_pair/2`
Existing good bundle already on disk  
→ candidate tampered Keygen bundle passed to `Licensing.install_pair/2`  
→ `normalize_bundle_pair/2`  
→ `read_node_identity/2`  
→ `Validator.validate_pair/2` fails  
→ function returns `{:error, %Licensing{...}}`  
→ `ensure_installable/1` and `LocalStore.write/2` are never reached  
→ on-disk bundle contents remain byte-for-byte unchanged

## Reuse vs. missing coverage

Reuse existing test helpers and inline builders; do **not** add fixtures or production changes.

What is missing today:

1. `install_pair/2` success path where both certificates are Keygen checkout format
2. explicit malformed Keygen envelope coverage for `alg`
3. explicit malformed Keygen envelope coverage for `sig` variants
4. `install_pair/2` preservation test for a tampered Keygen candidate bundle

# 3. **Design**

## A. Targeted change scope

This should remain a **single-file test extension** in `apps/orchard_shared/test/orchard/licensing_test.exs`.

Why this is not a refactor:

- Production logic already supports both envelope formats.
- Existing helpers already generate and mutate Keygen certificates.
- The gap is in the behavioral test matrix, not in code structure.
- Adding coverage in-place preserves the current test style and avoids introducing parallel test helpers or new fixtures.

No production file should change unless implementation reveals a genuine mismatch between current behavior and current tests; based on the provided code, that should not be necessary.

---

## B. `inspect_local/1` malformed Keygen envelope additions

Add **three new tests** under `describe "inspect_local/1"`, grouped next to the existing Keygen `enc` tests so the field-coverage matrix is obvious.

### 1. Unsupported `alg` in Keygen license certificate
Add a test with intent:

- Build a fully Keygen bundle:
  - `license_format: :keygen_checkout`
  - `machine_format: :keygen_checkout` or leave machine valid in any supported format; using both Keygen is cleaner
- Mutate `license_certificate` envelope `alg` to an unsupported value
- Write bundle and node identity
- Call `Licensing.inspect_local/1`

Expected assertions:

- `status.state == :malformed_license_certificate`
- `status.message == "certificate envelope format is invalid"`

Rationale: this exercises `Validator.extract_payload_and_signing_input/3` Keygen branch rejection without conflating it with base64 or signature verification.

### 2. Missing `sig` in Keygen machine certificate
Add a test with intent:

- Build a Keygen bundle
- Delete `"sig"` from `machine_certificate`
- Inspect locally

Expected assertions:

- `status.state == :malformed_machine_certificate`
- `status.message == "certificate signature is missing"`

Rationale: this locks down the `decode_signature_field/2` missing-field path for Keygen envelopes.

### 3. Non-string `sig` in Keygen license certificate
Add a test with intent:

- Build a Keygen bundle
- Replace `"sig"` with a non-binary value such as `123`
- Inspect locally

Expected assertions:

- `status.state == :malformed_license_certificate`
- `status.message == "certificate signature is missing"`

Rationale: current validator behavior treats non-binary `sig` the same as missing `sig`; this test confirms that existing contract rather than inventing a new one.

### Preserve current `enc` coverage
Do **not** replace or rewrite these two existing tests:

- missing `enc` → malformed license certificate
- non-string `enc` → malformed machine certificate

At most, move them so the Keygen malformed-envelope tests appear as a contiguous group:

- tampered signature
- tampered `enc`
- missing `enc`
- non-string `enc`
- unsupported `alg`
- missing `sig`
- non-string `sig`

That keeps the matrix readable without changing behavior.

### Helper additions for these tests
Add only minimal private helpers, implemented using the existing `mutate_certificate_envelope/2` pattern:

- helper to set envelope `"alg"` to an arbitrary value
- helper to delete envelope `"sig"`
- helper to set envelope `"sig"` to an arbitrary value

Illustrative shapes only:

```elixir
tamper_alg(certificate, value)
remove_sig(certificate)
tamper_sig(certificate, value)
```

These should mirror existing `tamper_enc/2` and `remove_enc/1`.

No new fixture files are needed.

---

## C. `install_pair/2` Keygen success-path addition

Add **one new test** under `describe "install_pair/2"` for a fully Keygen-formatted pair.

### Test behavior
Use `build_signed_bundle/6` with both certificates explicitly set to `:keygen_checkout`.

Suggested bundle shape:

- fingerprint: `@local_node_id`
- distinct license/machine ids for clarity
- validity window covering `@now`

Flow:

1. build Keygen bundle
2. write local node identity
3. call `Licensing.install_pair(bundle, opts(ctx))`

Expected assertions:

- returns `{:ok, %Licensing{} = status}`
- `status.state == :valid`
- optionally assert:
  - `status.license_id`
  - `status.machine_id`
  - `status.fingerprint == @local_node_id`
- persisted JSON file contains exactly:
  - `"license_certificate" => bundle.license_certificate`
  - `"machine_certificate" => bundle.machine_certificate`
- file mode remains `0600`

This should mirror the existing canonical success-path test, but use Keygen-format inputs to prove `install_pair/2` traverses the same write path after Keygen validation succeeds.

### Why reuse existing assertions
`install_pair/2` is format-agnostic after validator normalization; the only missing guarantee is that Keygen envelopes can reach the write stage successfully. Reusing the canonical success assertions verifies that without inventing a second assertion style.

---

## D. `install_pair/2` tampered Keygen preservation addition

Add **one new test** under `describe "install_pair/2"` proving a tampered Keygen candidate bundle does not overwrite the last good on-disk bundle.

### Test setup
Use a valid Keygen bundle as the installed baseline, not a canonical fixture, so the preservation test stays Keygen-specific end-to-end.

Flow:

1. build valid Keygen bundle
2. write it to `ctx.bundle_path`
3. write local node identity
4. create a candidate bundle by tampering the Keygen `license_certificate` signature
5. save `original_contents = File.read!(ctx.bundle_path)`
6. call `Licensing.install_pair(tampered_bundle, opts(ctx))`

Expected assertions:

- return matches `{:error, %Licensing{state: :invalid_license_signature}}`
- `File.read!(ctx.bundle_path) == original_contents`

Do **not** assert rewritten normalized JSON; compare the raw file contents instead, as the existing preservation test already does. That precisely proves no write happened.

### Why signature tamper is the right failure
A tampered Keygen signature exercises the real validation path:

- bundle shape remains syntactically valid
- Keygen branch is selected
- signature verification fails
- disk write is skipped

That is stronger than using a malformed JSON bundle or invalid top-level shape.

---

## E. Validation and test count expectations

## Expected count
The provided file currently contains **34 tests**. Adding exactly the five tests above yields **39 tests**.

Breakdown:

- `inspect_local/1`: +3
- `install_pair/2`: +2

## Validation command
Because this environment disallows tool execution, this must be performed by the implementer.

Run one of:

- from repo root:
  - `mix test apps/orchard_shared/test/orchard/licensing_test.exs`
- or from `apps/orchard_shared`:
  - `mix test test/orchard/licensing_test.exs`

Expected result after the planned changes:

- `39 tests`
- `0 failures`

## Unknown to validate during implementation
There is one behavior to verify from current code while writing assertions:

- **non-string `sig` currently reports `"certificate signature is missing"`**, not a type-specific message, because `decode_signature_field/2` only accepts `%{"sig" => binary}` and treats all other cases as missing.

Validation approach:

- align the new `sig` tests with the current validator contract shown in `validator.ex`
- if the implementation unexpectedly changes that behavior, update the test plan only if production behavior is intentionally changed across the whole suite

# 4. **File-by-file impact**

## `apps/orchard_shared/test/orchard/licensing_test.exs`
### What changes
- Add 3 `inspect_local/1` tests for malformed Keygen envelope fields:
  - unsupported `alg`
  - missing `sig`
  - non-string `sig`
- Add 1 `install_pair/2` success-path test for a fully Keygen-formatted bundle
- Add 1 `install_pair/2` failure-path preservation test for a tampered Keygen bundle
- Add minimal private helper(s) for envelope `alg`/`sig` mutation if not done inline:
  - `tamper_alg/2`
  - `remove_sig/1`
  - `tamper_sig/2`

### Why
This is the only missing coverage area; all production code paths already exist.

### Dependencies / ordering
- Add helpers before or after the new tests; no cross-file dependencies
- Keep new tests adjacent to existing Keygen tests to minimize churn and improve readability

## `apps/orchard_shared/lib/orchard/licensing.ex`
### What changes
- None expected

### Why
Current `install_pair/2` and `inspect_local/1` behavior already supports the requested scenarios.

## `apps/orchard_shared/lib/orchard/licensing/validator.ex`
### What changes
- None expected

### Why
Current malformed-envelope and Keygen-signature behavior already defines the assertions the new tests should cover.

## `apps/orchard_shared/lib/orchard/licensing/local_store.ex`
### What changes
- None expected

### Why
Existing atomic write semantics are already covered; the new Keygen preservation test only extends the validation-failure matrix.

# 5. **Implementation order**

1. **Add Keygen envelope mutation helpers**
   - Introduce `alg` and `sig` mutation helpers in `licensing_test.exs`, matching the style of `tamper_enc/2` and `remove_enc/1`.
   - Keep them private and envelope-only.

2. **Add the three malformed Keygen `inspect_local/1` tests**
   - unsupported `alg`
   - missing `sig`
   - non-string `sig`
   - Keep existing `enc` tests unchanged.

3. **Add the Keygen `install_pair/2` success test**
   - Use `build_signed_bundle/6` with both formats set to `:keygen_checkout`.
   - Reuse the canonical success assertions for persisted JSON and `0600` mode.

4. **Add the Keygen `install_pair/2` preservation test**
   - Seed a valid on-disk Keygen bundle.
   - Attempt install of a tampered Keygen bundle.
   - Assert invalid signature error and byte-for-byte file preservation.

5. **Run the single test file**
   - Execute the test file directly.
   - Confirm `39 tests`, `0 failures`.
   - If count differs, verify that exactly five new `test` blocks were added and no existing tests were removed or merged.

6. **Final review**
   - Confirm no production files changed.
   - Confirm new test names explicitly mention Keygen format so future regressions are easy to localize.


> 💡 Continue this plan conversation with ask_oracle(chat_id: "keygen-test-coverage-16466E", new_chat: false)