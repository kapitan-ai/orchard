# Responses client tools

`POST /v1/responses` accepts the canonical flattened function-tool form:

```json
{
  "model": "model-id@version",
  "input": "Read the fixture",
  "tools": [{
    "type": "function",
    "name": "read_file",
    "description": "Read a file on the client",
    "parameters": {
      "type": "object",
      "properties": {"path": {"type": "string"}},
      "required": ["path"],
      "additionalProperties": false
    },
    "strict": true
  }],
  "tool_choice": {"type": "function", "name": "read_file"},
  "stream": true
}
```

`strict` is preserved; it does not authorize tool execution. The model must pass
Orchard's existing tool-capability admission. `auto`, `none`, and `required` are
also supported choices. Unknown or ambiguous fields fail before dispatch.

OpenCode's string/null `prompt_cache_key` hint is accepted and ignored. It does
not select a cache, change tenant isolation, or grant reuse authority.

Nested Chat-style definitions and named choices remain a Responses compatibility
extension. `/v1/chat/completions` independently requires its nested dialect.
The Orchard extension `{"type":"function","ref":"tool://name@version"}` resolves
an active registry entry before rendering/tokenization/dispatch. Invalid,
unresolved and inactive refs are rejected; no unresolved ref reaches the runtime.

Clients execute calls and send explicit history on continuation:

```json
[
  {"role":"user","content":"Read the fixture"},
  {"type":"function_call","call_id":"call_7","name":"read_file","arguments":"{\"path\":\"fixture.txt\"}"},
  {"type":"function_call_output","call_id":"call_7","output":"fixture contents"}
]
```

Use that array as the next request's `input`. Preserve the returned `call_id`.
Multiple calls and results retain input order; each result must refer to a prior
call exactly once. Arguments must encode a JSON object and results must be
strings. Typed prior reasoning and server-side history references are unsupported.

For a successful stream, each call emits `response.output_item.added` with empty
arguments and `in_progress` status, an argument delta, argument done, and
`response.output_item.done` with completed arguments, followed by the terminal
`response.completed`. IDs and output indices match the terminal output array.
Orchard buffers call publication until selected-attempt completion; do not assume
argument deltas arrive token by token. Text remains separate and may stream early.
Failed or interrupted calls never receive a successful call lifecycle, and a
missing terminal event fails closed. Clients must treat stream closure as failure
unless they observed the required terminal event.

Controller, Node, Worker and provider do not execute these tools. Direct-client
conformance is not model, coding-agent, provider, or platform qualification.
See [the boundary decision](decisions/0034-responses-tool-boundary.md).
