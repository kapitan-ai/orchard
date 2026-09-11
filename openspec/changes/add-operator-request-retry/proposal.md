# Add the first operator Request retry slice (#411)

## Why

`SPEC.md` §§7.3.4 and 10.10 already require an operator-only retry of an eligible terminal Request when a complete retained canonical source exists. Orchard has durable retry lineage and capture-policy foundations, but no operator retry endpoint or atomic descendant reservation path.

Issue #327 is not merged. Its negotiated reasoning runtime identity cannot be reconstructed or renegotiated in this slice, so a retained negotiated snapshot must fail closed before a descendant is created or dispatched.

## What Changes

- Add the cluster-operator-only `POST /ops/v1/requests/:id/retry` endpoint.
- Permit only `failed`, `cancelled`, `timed_out`, and `interrupted` full-capture sources with a complete legacy canonical serialization.
- Atomically reserve at most three descendants per original Request, with each descendant pointing to that original Request.
- Reconstruct legacy canonical data without parser or normalizer re-entry; create a fresh descendant and dispatch it through the existing lifecycle and scheduler.
- Resolve retry capture to the narrower retained-source and current-tenant policy, including ordinary `store` resolution.
- Re-resolve current Model state and Tenant Model access inside the reservation transaction, apply the current grant's routing values without widening retained admission budgets, and fail closed with `retry_source_not_authorized` before any descendant exists.
- Return `retry_source_unavailable` without a row or dispatch for unavailable, malformed, or retained negotiated sources.
- Retain a created descendant and return a stable server error when its dispatch outcome cannot be recorded.

## Out Of Scope

- Automatic retry, request parsing, Runtime Endpoint or protobuf work, quotas, and public inference APIs.
- Negotiated reasoning retry support before #327 supplies a complete retained identity and compatible endpoint path.
- Changes to the retry limit, capture lattice, or terminal eligibility defined by `SPEC.md`.

## SPEC.md Impact

This implementation applies the existing requirements in `SPEC.md` §§7.3.4 and 10.10, and keeps the operator retry path consistent with the `SPEC.md` §5.2 admission steps that resolve an active Model and authorize Tenant Model access. It introduces no unresolved product-policy decision and does not modify `SPEC.md`.

## Impact

- `Orchard.API.Ops`, `Orchard.Requests`, and the existing request orchestration seam.
- Focused request, authorization, tenant-isolation, and scheduler-handoff tests.
