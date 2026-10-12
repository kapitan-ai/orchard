# Request-local native reasoning effort

## Why

Coding agents need to select a supported effort for each request on the same admitted model. Native prompt steering does not require final-only output or another weight identity.

## What Changes

- Accept Chat `reasoning_effort` and Responses `reasoning.effort`, with model-specific registered public identifiers and no fixed three-value ceiling; preserve the existing high compatibility alias and expose native xhigh for the exact first profile.
- Resolve a rendered input contract after model resolution and before tokenization or persistence. Preserve omitted requests exactly.
- Bind server-owned arguments to exact artifact/template identities, render/count once, and prove the selected/native values in the helper response.
- Preserve legacy blended output. Negotiated final-only parsing, privacy and runtime proof remain separate.
- Reject unsupported controls, tokenizer routes and structured prior reasoning without fallback.

## Impact

Affected capabilities: reasoning-output, automatic-attempt-retry. SPEC sections 3.4, 3.5 and 7.2.1 change. The existing qualified-effort change must be reconciled in this candidate; integration remains serialized with its source owners. No Worker protocol, model assets, dependency pins, GPU run or support claim changes.
