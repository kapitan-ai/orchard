## Boundary

ResponsesRequestValidator validates the public dialect before endpoint-local
normalization into the existing nested internal representation. Shared Chat
validation remains independent. Registry references remain an Orchard extension
resolved during preparation before rendering, tokenization and dispatch.

## Compatibility decision

Retain nested Responses tools and named choices for existing clients. Reject
mixed flattened/nested/ref objects rather than guessing intent. Canonical examples
use flattened definitions. Preserve strict verbatim; never execute client tools.

Accept the standard string/null prompt_cache_key hint used by OpenCode, but do
not propagate it to canonical cache identity or authorization. Unknown fields
remain rejected. This is compatibility only, not a cache-control capability.

## History and streaming

Map typed calls to assistant tool_calls and results to tool messages, preserving
call IDs and input order. Reject duplicate calls, orphan/duplicate results,
malformed arguments and unsupported input item kinds before preparation.
Responses presentation owns output item indices and IDs; every successful call
has added, argument delta/done and item done events before response.completed.
Calls are buffered until selected-attempt completion. Text has its own correlated
message lifecycle; all emitted events have increasing sequence numbers.
Interrupted or malformed streams must not mark incomplete calls complete.

## Validation

Deterministic ingress and stream tests cover mixed text/calls, multiple calls,
continuations, malformed inputs, registry refs, Chat independence and closure.
Direct installed-client evidence is separate from model/platform qualification.
