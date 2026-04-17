## Final Prompt
<taskname="Keygen Envelope Tests"/>
<task>Add test coverage for Keygen certificate envelope format in `apps/orchard_shared/test/orchard/licensing_test.exs`. Extend `sign_certificate/2` to support a format option (`:orchard_canonical` default, `:keygen_checkout`) and add Keygen-oriented cases for valid license, valid machine, tampered signature, tampered `enc` payload, missing `enc` malformed, and non-string `enc` malformed, while keeping existing Orchard-format tests passing.</task>

<architecture>
- `Orchard.LicensingTest` is the integration-style test module for `Orchard.Licensing.inspect_local/1` and related APIs; it contains local certificate builders and tamper helpers used to generate synthetic bundles.
- `Orchard.Licensing.Validator` performs certificate envelope decoding/signature verification and defines the envelope-format contract plus malformed/invalid-signature errors consumed by `Licensing.inspect_local/1`.
- `Orchard.Licensing` maps validator results into external states/messages asserted in tests.
</architecture>

<selected_context>
/Users/najib/Hacks/orchard/apps/orchard_shared/test/orchard/licensing_test.exs: Existing licensing tests and helper functions. Key helper/edit points:
- `build_signed_bundle/6` at ~505 builds license/machine payloads and currently calls `sign_certificate/2`.
- `sign_certificate/2` at ~556 currently emits Orchard canonical envelope only (`alg: "ed25519"`, `enc: "base64"`, `payload`, `sig`) and signs decoded payload JSON bytes.
- `tamper_signature/1` + envelope decode/encode helpers at ~486+ are existing mutation patterns for negative cases.
- Existing malformed envelope coverage includes non-object envelope JSON tests (message: `certificate envelope must be a JSON object`).

/Users/najib/Hacks/orchard/apps/orchard_shared/lib/orchard/licensing/validator.ex: Envelope format behavior under test.
- `extract_payload_and_signing_input/3` (~114):
  - Orchard canonical: requires `payload`, `alg == "ed25519"`, `enc == "base64"`; signing input is decoded payload JSON bytes.
  - Keygen checkout: requires `alg == "base64+ed25519"` and `enc`; decodes payload from `enc`; signing input is `"#{kind}/#{envelope["enc"]}"` (kind is lower-case atom string: `license`/`machine`).
  - Unknown format -> malformed certificate with message `certificate envelope format is invalid`.
- `decode_base64_field/3` (~179, ~189): non-string field gives `"<field> must be a string"`; invalid base64 gives `"<field> is not valid base64"`.
- `decode_json_object/3` (~156-162): non-object decoded envelope gives `"certificate envelope must be a JSON object"`.
- `decode_signature_field/2` requires `sig` string; missing gives `certificate signature is missing`.

/Users/najib/Hacks/orchard/apps/orchard_shared/lib/orchard/licensing.ex: Public status mapping for assertions (e.g., `:invalid_license_signature`, `:invalid_machine_signature`, `:malformed_license_certificate`, `:malformed_machine_certificate`) in `inspect_local/1`.
</selected_context>

<relationships>
- `LicensingTest.inspect_local` scenarios -> `Orchard.Licensing.inspect_local/1` -> `Orchard.Licensing.Validator.validate_pair/2`.
- Test helper `build_signed_bundle/6` -> `sign_certificate/...` output envelope -> validator `extract_payload_and_signing_input/3` branch selection.
- Tampering envelope fields in test helpers directly drives validator states/messages propagated by `Licensing.inspect_local/1`.
</relationships>

<ambiguities>
- The test module currently has a `sign_certificate/2` helper; adding format support may be done by introducing `sign_certificate/3` with default format behavior or by changing call sites in `build_signed_bundle/6`. Both are structurally compatible with current helpers.
- “Valid license” and “valid machine” Keygen cases can be modeled either as two focused failing-path tests (tamper one cert type at a time) or as successful full-bundle validation for each cert kind generated in Keygen format; validator supports Keygen for both cert kinds.
</ambiguities>

## Selection
- Files: 3 total (3 full)
- Total tokens: 11043 (Auto view)
- Token breakdown: full 11043

### Files
### Selected Files
/Users/najib/Hacks/orchard/
└── apps/
    └── orchard_shared/
        ├── lib/
        │   └── orchard/
        │       ├── licensing/
        │       │   └── validator.ex — 3,444 tokens (full)
        │       └── licensing.ex — 2,605 tokens (full)
        └── test/
            └── orchard/
                └── licensing_test.exs — 4,994 tokens (full)


---

## Generated Plan

## Chat Send ✅
- **Chat**: `keygen-envelope-tests-CB8B72` | **Mode**: plan

### Response
## 1. Summary

This is a **targeted test-only change** in `apps/orchard_shared/test/orchard/licensing_test.exs`. `Orchard.Licensing.Validator` already supports both Orchard-canonical and Keygen checkout certificate envelopes, so the right approach is to extend the existing test bundle builders/helpers to emit either format and add `inspect_local/1` coverage for the Keygen branch and its failure modes. No production refactor is warranted.

## 2. Current-state analysis

### Existing responsibilities

- `Orchard.LicensingTest`
  - Integration-style tests for `Orchard.Licensing.inspect_local/1`, `install_pair/2`, `health_summary/1`, and `startup_decision/2`.
  - Owns synthetic bundle generation:
    - `build_signed_bundle/6`
    - `sign_certificate/2`
    - `tamper_signature/1`
    - `decode_certificate_envelope/1`
    - `encode_certificate/3`
    - `wrap_base64/1`
  - Writes bundle JSON to disk and asserts public `Orchard.Licensing` states/messages.

- `Orchard.Licensing`
  - Reads bundle from `LocalStore`.
  - Reads node identity from `NodeIdentityFile`.
  - Delegates cryptographic validation to `Orchard.Licensing.Validator.validate_pair/2`.
  - Maps validator errors into public `state`/`message` values asserted by tests.

- `Orchard.Licensing.Validator`
  - Validates the configured Ed25519 public key.
  - Parses each certificate envelope.
  - Supports **two envelope formats** in `extract_payload_and_signing_input/3`:
    1. **Orchard canonical**
       - `alg == "ed25519"`
       - `enc == "base64"`
       - `payload` contains base64 JSON
       - signature is over decoded JSON bytes
    2. **Keygen checkout**
       - `alg == "base64+ed25519"`
       - `enc` contains base64 JSON
       - signature is over `"#{kind}/#{enc}"`, where `kind` is `"license"` or `"machine"`
  - Returns either normalized claims or `{state, message}` tuples.

### End-to-end flow under test

`LicensingTest.inspect_local` case  
→ writes synthetic bundle JSON + node identity  
→ `Orchard.Licensing.inspect_local/1`  
→ `read_bundle/1` + `read_node_identity/2`  
→ `Validator.validate_pair/2`  
→ per certificate:
`extract_signed_payload/2`
→ `decode_signed_envelope/3`
→ `extract_payload_and_signing_input/3`
→ `verify_signature/3`
→ `decode_payload_json/2`
→ `normalize_certificate_payload/2`
→ `normalize_pair/2`
→ `Licensing.claims_to_status/4`
→ asserted public `state` / `message`

### What is reusable

- Existing certificate envelope decode/re-encode helpers in the test file should be reused.
- Existing Orchard-format tests should remain unchanged and continue using the default signing behavior.
- Existing `tamper_signature/1` pattern is the right mutation style for new Keygen-negative cases.

### What is missing / blocking

The test helper `sign_certificate/2` only emits Orchard canonical envelopes, so the test suite cannot currently exercise:
- valid Keygen license envelope acceptance
- valid Keygen machine envelope acceptance
- Keygen-specific `enc` failure paths

## 3. Design

### A. Extend test certificate generation helpers

#### Modified helper signatures

In `apps/orchard_shared/test/orchard/licensing_test.exs`:

- Change certificate builder helper from:
  - `sign_certificate(kind, payload)`
- To:
  - `sign_certificate(kind, payload, format \\ :orchard_canonical)`

Use a closed two-value format set:

```elixir
:orchard_canonical | :keygen_checkout
```

#### Envelope shapes to generate

**Orchard canonical** (current behavior; unchanged default)

```elixir
%{
  "alg" => "ed25519",
  "enc" => "base64",
  "payload" => Base.encode64(payload_json),
  "sig" => Base.encode64(sign(payload_json))
}
```

**Keygen checkout** (new test helper behavior)

```elixir
base64_payload = Base.encode64(payload_json)

%{
  "alg" => "base64+ed25519",
  "enc" => base64_payload,
  "sig" => Base.encode64(sign("#{kind_downcased}/#{base64_payload}"))
}
```

Important contract details:
- `kind_downcased` must be `"license"` or `"machine"`, matching validator behavior.
- The `enc` value used in the signature input must be the exact string stored in the envelope JSON.
- PEM-style outer header/footer remain unchanged:
  - `-----BEGIN LICENSE FILE-----`
  - `-----END LICENSE FILE-----`
  - `-----BEGIN MACHINE FILE-----`
  - `-----END MACHINE FILE-----`

#### Build helper changes

Extend `build_signed_bundle/6` keyword overrides to support per-certificate format selection:

- `license_format: :orchard_canonical | :keygen_checkout`
- `machine_format: :orchard_canonical | :keygen_checkout`

Default both to `:orchard_canonical` so all existing tests remain valid without edits.

This is better than a bundle-wide single format flag because the requested “valid license” and “valid machine” cases are easiest to express as mixed-format bundles that isolate one cert kind at a time.

### B. Add reusable envelope mutation helper for negative cases

Add one private helper in the test module to mutate decoded envelope JSON and re-encode the certificate. Shape:

```elixir
mutate_certificate_envelope(certificate, fn envelope -> ... end)
```

Use it to implement or simplify:
- existing `tamper_signature/1`
- new Keygen `enc` mutations

This is a small justified refactor because three new tests all mutate inner envelope fields.

### C. New `inspect_local/1` Keygen coverage

Add six new tests under `describe "inspect_local/1"`.

#### 1. Valid Keygen license certificate

Purpose:
- Exercise Keygen branch for `:license` while keeping `:machine` on known-good Orchard default.

Bundle shape:
- `license_format: :keygen_checkout`
- `machine_format: :orchard_canonical`

Expected result:
- `status.state == :valid`
- `status.message == "License bundle is valid."`
- assert representative fields (`license_id`, `machine_id`, `fingerprint`) to confirm normal claim decoding still works.

#### 2. Valid Keygen machine certificate

Purpose:
- Exercise Keygen branch for `:machine` independently.

Bundle shape:
- `license_format: :orchard_canonical`
- `machine_format: :keygen_checkout`

Expected result:
- same `:valid` assertions as above.

#### 3. Keygen tampered signature

Purpose:
- Prove Keygen envelope still maps bad signature to the public invalid-signature state.

Recommended cert kind:
- use **license** certificate so coverage is split across kinds.

Mutation:
- create Keygen license cert, replace `"sig"` with a different valid-length base64 signature.

Expected result:
- `status.state == :invalid_license_signature`
- `status.message == "License certificate signature is invalid."`

#### 4. Keygen tampered `enc` payload

Purpose:
- Prove that changing `enc` without re-signing fails signature verification, not structural decoding.

Recommended cert kind:
- use **machine** certificate.

Mutation requirements:
- replace `"enc"` with a **different valid base64 string**.
- That new base64 should decode successfully; ideally decode to valid JSON to make the test intent explicit.
- Do **not** update `"sig"`.

Expected result:
- `status.state == :invalid_machine_signature`
- `status.message == "Machine certificate signature is invalid."`

Rationale:
`decode_certificate/3` verifies signature before JSON payload parsing, so a changed but base64-valid `enc` should land in the invalid-signature path.

#### 5. Keygen missing `enc` malformed

Purpose:
- Exercise the “unknown envelope format” branch when `alg` says Keygen checkout but `enc` is absent.

Recommended cert kind:
- use **license** certificate.

Mutation:
- remove `"enc"` from a Keygen license envelope.

Expected result:
- `status.state == :malformed_license_certificate`
- `status.message == "certificate envelope format is invalid"`

Rationale:
`extract_payload_and_signing_input/3` requires `Map.has_key?(envelope, "enc")` for Keygen checkout.

#### 6. Keygen non-string `enc` malformed

Purpose:
- Exercise base64-field type validation for Keygen `enc`.

Recommended cert kind:
- use **machine** certificate.

Mutation:
- set `"enc"` to a non-binary value such as an integer.

Expected result:
- `status.state == :malformed_machine_certificate`
- `status.message == "payload must be a string"`

Important note:
Although the mutated field is `enc`, the validator currently reports this as `"payload must be a string"` because `decode_base64_field/3` is called with `field_name = "payload"`. Tests should assert the current public behavior, not rename it.

### D. API/interface impact

No production APIs change.

Test-private helper interface changes in `licensing_test.exs`:

#### Before
```elixir
defp sign_certificate(kind, payload)
defp build_signed_bundle(fingerprint, license_id, machine_id, not_before, expiry, overrides \\ [])
```

#### After
```elixir
defp sign_certificate(kind, payload, format \\ :orchard_canonical)
defp build_signed_bundle(fingerprint, license_id, machine_id, not_before, expiry, overrides \\ [])
# new supported override keys:
#   :license_format
#   :machine_format
```

Call sites to update:
- Only inside `apps/orchard_shared/test/orchard/licensing_test.exs`
  - `build_signed_bundle/6`
  - new Keygen-specific tests
- Existing two-arg `sign_certificate` use sites can remain unchanged because of the default.

### E. Concurrency, persistence, and error handling

- No concurrency model changes.
- No persistence schema changes.
- Disk I/O behavior in tests remains the same:
  - write synthetic bundle JSON
  - write node identity
  - call `Licensing.inspect_local/1`

Edge cases to preserve:
- Existing Orchard-format tests must keep passing with no changed assertions.
- Mixed-format bundles must still validate because `validate_pair/2` validates certs independently and only requires normalized claims to match.

## 4. File-by-file impact

### `/Users/najib/Hacks/orchard/apps/orchard_shared/test/orchard/licensing_test.exs`

#### What changes
- Modify `sign_certificate` helper to accept an optional format.
- Modify `build_signed_bundle/6` to accept `license_format` and `machine_format` overrides.
- Add one generic envelope mutation helper, or equivalent targeted helpers, for `enc` edits/removal.
- Add six `inspect_local/1` tests covering:
  - valid Keygen license
  - valid Keygen machine
  - tampered signature
  - tampered `enc`
  - missing `enc`
  - non-string `enc`

#### Why
- This is the only place synthetic certificate envelopes are created.
- The validator already supports the Keygen format; the missing coverage is entirely in test generation and assertions.

#### Dependencies / ordering
- Helper signature changes must land before adding the new tests.
- If `tamper_signature/1` is migrated to use the new generic mutator, do that before adding the other mutation-based tests so all envelope editing follows one path.

## 5. Risks and migration

Not applicable beyond normal test maintenance; this is a non-breaking test-only change.

Implementation-time validation to perform:
- Confirm the Keygen signing input uses lowercase `"license"` / `"machine"` exactly.
- Confirm the expected malformed messages:
  - missing `enc` → `"certificate envelope format is invalid"`
  - non-string `enc` → `"payload must be a string"`

If either assertion differs during implementation, treat that as a validator-contract check and reconcile against `extract_payload_and_signing_input/3` and `decode_base64_field/3` before changing test expectations.

## 6. Implementation order

1. **Extend helper API**
   - Add `format \\ :orchard_canonical` to `sign_certificate`.
   - Add `license_format` / `machine_format` override handling to `build_signed_bundle`.
   - Keep existing callers working unchanged.

2. **Add envelope mutation support**
   - Introduce a single envelope-mutator helper.
   - Optionally rebase `tamper_signature/1` onto it.

3. **Add positive Keygen coverage**
   - Add “valid Keygen license” test.
   - Add “valid Keygen machine” test.

4. **Add negative Keygen coverage**
   - Add tampered signature test.
   - Add tampered `enc` payload test.
   - Add missing `enc` malformed test.
   - Add non-string `enc` malformed test.

5. **Regression-check Orchard behavior**
   - Verify existing Orchard-format tests still pass without assertion changes.
   - Verify new mixed-format tests do not require production code changes.


> 💡 Continue this plan conversation with ask_oracle(chat_id: "keygen-envelope-tests-CB8B72", new_chat: false)