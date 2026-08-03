# Enforce inference capture modes

## Why

Orchard labels every inference Request as `metadata` capture while retaining the full canonical request and, for non-streaming success, the full response.
Request event payloads can also retain model-generated tool arguments and untrusted error text.
This conflicts with `SPEC.md` section 10.10 and prevents an accurate privacy or retention statement.

## What changes

- Persist and validate the Tenant request-body capture mode with `metadata` as the default.
- Resolve an effective mode for each logical Request and snapshot it on the Request row.
- Enforce `none`, `metadata`, and `full` at the Requests persistence boundary for request rows and request events.
- Define bounded metadata shape, non-equivalent previews, request and response hashes, stable error codes, and content-bearing column constraints.
- Make `store=false` narrow `full` to `metadata` and never widen Tenant policy.
- Define idempotency replay and future operator retry behavior when source payloads are intentionally unavailable.
- Purge existing mislabeled rows and verify every enumerated content-bearing column.

## SPEC.md impact

This change reconciles `SPEC.md` sections 7.3.4, 7.4.2, the requests schema in section 9, and section 10.10.
It makes `canonical_request` nullable outside `full`, defines the metadata-only shape and preview bounds, and records fail-safe replay and retry behavior.

## Out of scope

- Automatic inference retry.
- A general retention scheduler.
- Backup expiry, WAL recycling, or cryptographic erasure.
- Sentry or other external telemetry filtering.
- A new Tenant administration API beyond accepting the capture field in existing governance creation paths.
