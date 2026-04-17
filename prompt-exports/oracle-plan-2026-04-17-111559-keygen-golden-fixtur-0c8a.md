## Final Prompt
<taskname="Keygen Golden Fixture"/>
<task>Add a golden fixture test in `apps/orchard_shared/test/orchard/licensing_test.exs` that uses real captured Keygen certificate data (alg `base64+ed25519`, real `enc`/`sig`) to prove `Orchard.Licensing.inspect_local/1` validates authentic Keygen envelopes and that signing-input semantics match real Keygen output. Keep scope to test coverage only (fixture file optional), avoid production behavior changes unless tests require it, and run focused validation commands.</task>

<architecture>`Orchard.Licensing.inspect_local/1` (`licensing.ex`) reads bundle + node identity, delegates certificate verification to `Orchard.Licensing.Validator.validate_pair/2`, then maps validator outcomes into public status states/messages asserted by tests. `Validator` supports two envelope modes: Orchard canonical (`alg=ed25519`, `payload`, `enc=base64`) and Keygen checkout (`alg=base64+ed25519`, `enc`, signing input is `"#{kind}/#{enc}"`). `licensing_test.exs` is the main integration-style suite and already contains helper builders (`build_signed_bundle/6`, `sign_certificate/3`) plus Keygen synthetic-path tests.</architecture>

<selected_context>
/Users/najib/Hacks/orchard/apps/orchard_shared/test/orchard/licensing_test.exs: Primary edit target. Existing `inspect_local/1` tests already cover synthetic Keygen envelopes and envelope tampering; helper APIs to reuse include `load_fixture_bundle!/1`, `copy_fixture!/2`, `build_signed_bundle/6`, `sign_certificate/3`, `decode_certificate_envelope/1`, and envelope mutators.
/Users/najib/Hacks/orchard/apps/orchard_shared/lib/orchard/licensing/validator.ex: Source of signing semantics and expected malformed/invalid-signature errors. Key functions: `decode_certificate/3`, `extract_payload_and_signing_input/3`, `decode_base64_field/3`, `verify_signature/3`.
/Users/najib/Hacks/orchard/apps/orchard_shared/lib/orchard/licensing.ex: Maps validator tuples to external status (`:valid`, `:invalid_license_signature`, `:malformed_license_certificate`, etc.) and messages asserted in tests.
/Users/najib/Hacks/orchard/apps/orchard_shared/lib/orchard/licensing/local_store.ex: Bundle JSON contract (`license_certificate`, `machine_certificate`) and persistence behavior used by `inspect_local/1`/`install_pair/2` flows.
/Users/najib/Hacks/orchard/apps/orchard_shared/lib/orchard/node_identity_file.ex: Node fingerprint read path used by `inspect_local/1` setup.
/Users/najib/Hacks/orchard/apps/orchard_shared/test/fixtures/licensing/valid_bound_to_local.json: Canonical fixture structure and certificate wrapping style.
/Users/najib/Hacks/orchard/apps/orchard_shared/test/fixtures/licensing/valid_bound_to_other_node.json: Existing mismatch fixture pattern.
/Users/najib/Hacks/orchard/apps/orchard_shared/test/fixtures/licensing/expired.json: Existing expiry fixture pattern.
/Users/najib/Hacks/orchard/apps/orchard_shared/test/fixtures/licensing/malformed.json: Existing malformed fixture shape.
/Users/najib/Hacks/orchard/apps/orchard_shared/test/orchard/artifact_bundle_test.exs: Example of regression-lock/golden-style fixture testing pattern in same app test suite.
/Users/najib/Hacks/orchard/prompt-exports/oracle-plan-2026-04-17-095418-keygen-sig-verify-dc-8313.md: Prior investigation context documenting Keygen signing-input expectations and identified test gaps.
/Users/najib/Hacks/orchard-workbench/todos/archive/2026-04/todo-keygen-public-key-cert-verification.md: Provenance for real captured `.lic` artifacts and local verification evidence (external artifact paths referenced here).
</selected_context>

<relationships>
- `LicensingTest` -> `Licensing.inspect_local/1` -> `Validator.validate_pair/2` -> status mapping in `Licensing`.
- `Validator.extract_payload_and_signing_input/3` determines signing bytes:
  - canonical: verify decoded payload JSON bytes
  - Keygen checkout: verify `"license/<enc>"` or `"machine/<enc>"`.
- Test helper envelope mutations in `licensing_test.exs` directly drive validator error branches and resulting `Licensing` state/message assertions.
- Fixture JSON files define on-disk bundle contract consumed by `LocalStore.read/1` and test helper `load_fixture_bundle!/1`.
</relationships>

<ambiguities>
- Real captured certificate blobs are referenced as external artifacts (`~/Hacks/keygen-inspector/artifacts/orchard-license.lic` and `.../orchard-machine.lic`) and are not present in this repo selection; if exact captured `enc`/`sig` values were provided separately by the user, embed them into a new fixture JSON under `apps/orchard_shared/test/fixtures/licensing/` or inline constants in `licensing_test.exs`.
- `apps/orchard_shared/test/orchard/licensing_test.exs` is currently modified in the working tree; preserve existing in-flight edits while adding the golden fixture case.
- “Run relevant validation commands” likely means at minimum focused test runs in `orchard`: `mix test apps/orchard_shared/test/orchard/licensing_test.exs` (and optionally app-level shared suite).
</ambiguities>

## Selection
- Files: 12 total (12 full)
- Total tokens: 25244 (Auto view)
- Token breakdown: full 25244

### Files
### Selected Files
/Users/najib/Hacks/orchard/
├── apps/
│   └── orchard_shared/
│       ├── lib/
│       │   └── orchard/
│       │       ├── licensing/
│       │       │   ├── local_store.ex — 906 tokens (full)
│       │       │   └── validator.ex — 3,444 tokens (full)
│       │       ├── licensing.ex — 2,605 tokens (full)
│       │       └── node_identity_file.ex — 957 tokens (full)
│       └── test/
│           ├── fixtures/
│           │   └── licensing/
│           │       ├── expired.json — 360 tokens (full)
│           │       ├── malformed.json — 18 tokens (full)
│           │       ├── valid_bound_to_local.json — 363 tokens (full)
│           │       └── valid_bound_to_other_node.json — 363 tokens (full)
│           └── orchard/
│               ├── artifact_bundle_test.exs — 1,045 tokens (full)
│               └── licensing_test.exs — 6,666 tokens (full)
└── prompt-exports/
    └── oracle-plan-2026-04-17-095418-keygen-sig-verify-dc-8313.md — 6,989 tokens (full)
/Users/najib/Hacks/orchard-workbench/
└── todos/
    └── archive/
        └── 2026-04/
            └── todo-keygen-public-key-cert-verification.md — 1,528 tokens (full)


---

## Generated Plan

## Chat Send ✅
- **Chat**: `keygen-golden-fixture-257701` | **Mode**: plan

### Response
# 1. Summary

Add a targeted golden-regression test to `apps/orchard_shared/test/orchard/licensing_test.exs` backed by a new real-artifact fixture JSON under `apps/orchard_shared/test/fixtures/licensing/`. Reuse the existing `inspect_local/1` integration path and test helpers, add only test-local envelope inspection/signature assertions, and avoid production changes unless the real captured Keygen artifacts reveal an actual validator mismatch.

# 2. Current-state analysis

## Relevant code path today

`Orchard.Licensing.inspect_local/1` in `apps/orchard_shared/lib/orchard/licensing.ex` does this synchronously in-process:

1. `resolve_config/1` builds runtime config.
2. `read_bundle/1` calls `Orchard.Licensing.LocalStore.read/1`.
3. `read_node_identity/2` calls `Orchard.NodeIdentityFile.read/1`.
4. `Orchard.Licensing.Validator.validate_pair/2` validates both certificates.
5. `claims_to_status/4` maps normalized claims into `%Orchard.Licensing{}`.

There are no mutations inside `inspect_local/1`; all filesystem mutation in this test module happens in setup helpers (`write_bundle!/2`, `copy_fixture!/2`, `write_node_identity!/2`) against per-test temp directories.

## Validator responsibilities

`apps/orchard_shared/lib/orchard/licensing/validator.ex` owns:

- PEM-like wrapper parsing via `extract_signed_payload/2`
- outer body base64 decode
- envelope JSON decode
- signature input selection in `extract_payload_and_signing_input/2`
- Ed25519 verification in `verify_signature/3`
- claim normalization and cross-certificate license ID matching

Supported envelope variants already in code:

- Orchard canonical:
  - `alg == "ed25519"`
  - `enc == "base64"`
  - `payload == <base64 json>`
  - verify decoded payload bytes
- Keygen checkout:
  - `alg == "base64+ed25519"`
  - `enc == <base64 json>`
  - verify `"#{kind}/#{enc}"`

## Existing reusable test surface

`apps/orchard_shared/test/orchard/licensing_test.exs` already has the right seams to extend:

- fixture loading: `load_fixture_bundle!/1`, `copy_fixture!/2`
- temp-path option building: `opts/2`
- envelope inspection/mutation: `decode_certificate_envelope/1`, `tamper_signature/1`, `tamper_enc/2`, `remove_enc/1`
- synthetic Keygen-path coverage via `build_signed_bundle/6` and `sign_certificate/3`

That means this request should extend the existing integration test module rather than introduce a new test module or refactor production validator code.

## What is currently missing

The current suite proves synthetic Keygen envelopes created by local test helpers, but it does **not** lock behavior against a real captured Keygen certificate pair. The gap is specifically:

- no checked-in real `alg=base64+ed25519` artifact
- no assertion that authentic captured `enc`/`sig` validate through `Licensing.inspect_local/1`
- no golden assertion that the real artifact verifies with `"license/" <> enc` / `"machine/" <> enc` and **not** with decoded payload bytes alone

# 3. Design

## A. Golden fixture artifact

### New file
Add:

- `apps/orchard_shared/test/fixtures/licensing/keygen_golden.json`

### File kind and ownership
- Kind: static JSON fixture
- Owner: `LicensingTest`
- Lifecycle: read-only test asset committed to the repo

### Exact shape
Use the same bundle contract enforced by `LocalStore.read/1`:

```json
{
  "license_certificate": "<exact captured LICENSE FILE text>",
  "machine_certificate": "<exact captured MACHINE FILE text>"
}
```

### Source of truth
Populate both strings from the real captured Keygen artifacts referenced in the workbench notes, preserving:

- exact inner `enc`
- exact `sig`
- original certificate delimiters
- original line wrapping
- trailing newline inside each certificate string if present in the captured artifact

### Why a fixture file, not inline strings
A dedicated fixture matches the existing `fixtures/licensing/*.json` pattern and makes this a stable regression lock rather than a large opaque constant embedded in the test module.

### Validation unknown to resolve during implementation
Because the real artifacts are outside the repo selection, the implementer must verify before commit that:

- the captured pair is from a safe sandbox/test account
- the payload contains no secret material that should remain out of git
- the checked-in strings are byte-identical to the captured source artifacts

Suggested validation: compare the copied certificate text byte-for-byte against the external source before committing.

## B. `LicensingTest` golden-path coverage

### Modified file
- `apps/orchard_shared/test/orchard/licensing_test.exs`

### Change scope
Add tests only; do not change existing production modules up front.

### New assertions to add

#### 1. Real Keygen fixture validates end-to-end through `inspect_local/1`
Add one `describe "inspect_local/1"` test that:

- copies `keygen_golden.json` to `ctx.bundle_path`
- writes the matching captured machine fingerprint to `ctx.node_identity_path`
- calls `Licensing.inspect_local(opts(ctx))`
- asserts:
  - `state == :valid`
  - `message == "License bundle is valid."`
  - `bundle_path == ctx.bundle_path`
  - `fingerprint == <captured fingerprint>`
  - `local_node_fingerprint == <captured fingerprint>`
  - `license_id == <captured license id>`
  - `machine_id == <captured machine id>`
  - `licensee == <captured licensee or nil>`
  - `max_machines == <captured integer or nil>`
  - `expires_at == <captured DateTime>`

Do not reuse `@local_node_id` unless the real captured artifact happens to match it; use explicit golden expected values for the real artifact.

#### 2. Real Keygen envelopes have the expected provider format
Add a focused test-local envelope inspection assertion using `decode_certificate_envelope/1` against both certificates:

- `envelope["alg"] == "base64+ed25519"`
- `is_binary(envelope["enc"])`
- `is_binary(envelope["sig"])`
- `Map.has_key?(envelope, "payload") == false`

This proves the golden fixture is actually exercising provider output, not the Orchard canonical format.

#### 3. Signing-input semantics match real captured output
Add a test-local crypto assertion for both certificates:

- decode the envelope with `decode_certificate_envelope/1`
- base64-decode `sig`
- base64-decode `enc` into `payload_json`
- assert `:crypto.verify/5` succeeds for:
  - `"license/" <> enc`
  - `"machine/" <> enc`
- assert verification fails for decoded `payload_json`

That test should be implemented entirely in `licensing_test.exs`; do **not** add a production debug helper for this request unless the test cannot express the check cleanly.

This is the key design choice: prove raw captured semantics in test code, not by expanding the production API.

### Test-local helpers to add
Prefer minimal private helpers inside `LicensingTest`, for example shapes like:

```elixir
load_golden_claims!() :: %{
  fingerprint: String.t(),
  license_id: String.t(),
  machine_id: String.t(),
  licensee: String.t() | nil,
  max_machines: pos_integer() | nil,
  expires_at: DateTime.t() | nil
}

assert_real_keygen_signature_input!(certificate, :license | :machine) :: :ok
```

Implementation detail to resolve in test code:

- derive expected claims once from the decoded payload and pin them as module attributes, or
- decode the payload in the test and assert against explicit literals

For a true golden regression, prefer explicit module attributes for the expected claims rather than only deriving expectations from the same artifact under test.

## C. Data flow for the new tests

### `inspect_local/1` golden test
Trigger:
- ExUnit test case

Flow:
1. fixture file `keygen_golden.json`
2. `copy_fixture!/2` writes to temp bundle path
3. `write_node_identity!/2` writes captured fingerprint to temp node-id path
4. `Licensing.inspect_local/1`
5. `LocalStore.read/1` decodes JSON bundle
6. `NodeIdentityFile.read/1` reads node fingerprint
7. `Validator.validate_pair/2` validates real Keygen envelopes
8. `claims_to_status/4` produces `%Licensing{}`
9. ExUnit asserts public status fields

Thread/process context:
- single async ExUnit test process
- isolated temp directory per test
- read-only shared fixture access, so no cross-test race

Out-of-order/duplication handling:
- not applicable; all steps are synchronous and local

### Signing-input semantics test
Trigger:
- ExUnit test case

Flow:
1. `load_fixture_bundle!("keygen_golden")`
2. `decode_certificate_envelope/1`
3. extract `enc` and `sig`
4. test-local `:crypto.verify/5` calls with:
   - correct input: `"#{kind}/" <> enc`
   - incorrect input: decoded payload JSON
5. ExUnit asserts true/false behavior

This test bypasses `Licensing.inspect_local/1` intentionally to isolate the signing-input invariant without duplicating full status mapping assertions.

## D. API, persistence, and compatibility

### Production API changes
None planned.

No changes to:

- `Orchard.Licensing.inspect_local/1`
- `Orchard.Licensing.install_pair/2`
- `Orchard.Licensing.Validator.validate_pair/2`
- `LocalStore` bundle schema

### Persistence changes
None.

`keygen_golden.json` uses the existing persisted bundle schema and does not introduce migration or compatibility concerns.

## E. Concurrency and lifecycle

Relevant constraints remain unchanged:

- `LicensingTest` is `async: true`
- each test already creates unique temp paths
- new golden fixture file is read-only and safe for concurrent access
- no new processes, tasks, or shared mutable state are introduced

## F. Error handling and edge cases

### Expected failure modes during implementation
If the new golden test fails, the likely categories are:

1. **Fixture import mismatch**
   - copied certificate text differs from the original captured artifact
   - likely symptom: invalid signature

2. **Captured artifact shape differs from assumed Keygen envelope**
   - extra/missing fields or different wrapping
   - likely symptom: malformed certificate

3. **Expected claims pinned incorrectly**
   - artifact validates, but explicit expected IDs/fingerprint/licensee do not match
   - likely symptom: assertion failure only

### Required implementation rule
Do not make production validator changes until the implementer has first validated which of the above failed. The request scope is test coverage only.

# 4. File-by-file impact

## `apps/orchard_shared/test/fixtures/licensing/keygen_golden.json`
- **What changes:** new fixture file containing the real captured `license_certificate` and `machine_certificate`.
- **Why:** establishes a stable, authentic regression artifact for Keygen checkout envelopes.
- **Dependencies:** must be added before the new golden tests can run.

## `apps/orchard_shared/test/orchard/licensing_test.exs`
- **What changes:**
  - add module attributes for the golden fixture name and the expected captured claims
  - add one `inspect_local/1` golden test using `keygen_golden.json`
  - add one test asserting the real envelope format is `base64+ed25519`
  - add one test-local signature-input semantics check proving `"#{kind}/#{enc}"` verifies and decoded payload bytes do not
  - add minimal private helpers only if needed to keep the tests readable
- **Why:** this is the existing integration-style licensing suite and already owns the helper surface for fixture loading and envelope inspection.
- **Dependencies:** depends on the new fixture file; should not depend on production code changes unless the real artifact exposes a true validator gap.

# 5. Risks and migration

No migration work.

Primary risk is committing real captured artifacts that contain unintended customer-identifying data. Validate provenance and sensitivity before adding `keygen_golden.json`. If the captured pair is not safe to commit, stop and replace the plan with a local-only validation strategy instead of checking it into the repo.

# 6. Implementation order

1. **Create the golden fixture**
   - Add `apps/orchard_shared/test/fixtures/licensing/keygen_golden.json`.
   - Copy the exact captured certificate strings into the standard bundle JSON shape.
   - Validate byte-for-byte parity against the external captured artifacts.

2. **Pin the expected claims in `licensing_test.exs`**
   - Add explicit expected values for fingerprint, license ID, machine ID, licensee, max machines, and expiry from the captured artifact.
   - Use new attrs/constants rather than reusing the existing synthetic IDs.

3. **Add the end-to-end `inspect_local/1` golden test**
   - Copy the fixture, write the matching node identity, call `Licensing.inspect_local/1`, assert the full valid status surface.

4. **Add the signing-semantics regression test**
   - Decode the real envelope with existing helpers.
   - Assert the real signature verifies with `"#{kind}/#{enc}"` and not with decoded payload bytes.

5. **Run focused validation**
   - From repo root:
     ```bash
     mix test apps/orchard_shared/test/orchard/licensing_test.exs
     ```
   - If you want one extra confidence pass limited to the app:
     ```bash
     mix test apps/orchard_shared/test/orchard
     ```

## Unknowns to validate during implementation

- **Exact captured values are not present in the provided context.**  
  Validation approach: read the external `.lic` artifacts referenced in the workbench notes, copy them exactly, and decode once locally to extract the expected claim literals.

- **Captured fingerprint may differ from `@local_node_id`.**  
  Validation approach: derive the machine fingerprint from the real machine certificate and use that exact value in the node identity setup for the golden test.

- **Real artifact safety for check-in is not proven by the provided files.**  
  Validation approach: confirm the artifacts are from a sandbox/test license and contain only intended public certificate material before committing.


> 💡 Continue this plan conversation with ask_oracle(chat_id: "keygen-golden-fixture-257701", new_chat: false)