## Why

The canonical Responses endpoint currently accepts Chat-shaped tools and exposes
calls only in terminal stream payloads. Standard Responses clients require an
endpoint-local translation and typed call lifecycle without a protocol relay.

## What Changes

- Update SPEC.md §7.2.5 to accept flattened function tools and named choices,
  retaining nested definitions as an explicit compatibility extension.
- Accept ordered function_call/function_call_output input history.
- Emit correlated Responses function-call lifecycle events.
- Preserve registry resolution, capability admission, strict and client execution.

## Impact

Responses ingress and presentation only; no shared Chat dialect inference,
provider/model/platform qualification, or server-side tool execution.
