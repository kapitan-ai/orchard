## Why

Orchard's optional Sentry crash reporting currently applies a recursive denylist after `Sentry.PlugContext` has collected request data. Real `/v1/responses` and `/v1/chat/completions` bodies contain prompts, instructions, tool definitions, tool choices, metadata, and other proprietary or customer-controlled values that are not exhaustively named by that denylist. A deterministic reproduction confirms that `request.data.instructions` and `request.data.tools` survive the current outbound filter.

The same integration removes all source paths, does not provide stable Product Version and component tags for background crashes, and relies on SDK defaults that expose more diagnostic inventory than the internal rollout needs. The internal rollout needs fail-closed payload minimization and useful first-party crash provenance before any real event is sent. A controlled source-development preflight also confirmed that hosted Sentry derives `user.geo` from the ingest connection even when IP-address storage prevention is enabled, so every real smoke gate requires explicit server-side removal of that post-ingest augmentation.

## What Changes

- Collect only the HTTP method into process-local Sentry request context and reconstruct outbound request interfaces from the same allowlist.
- Remove request bodies, headers, cookies, URLs, query strings, remote addresses, user data, and all other request fields from every outbound event.
- Rebuild actual Sentry events from an allowlist so free-form messages, exception values, unknown extras, unknown tags, non-Orchard breadcrumbs, contexts, modules, and attachments cannot bypass request scrubbing; apply semantic validators to every retained diagnostic key.
- Rebuild rather than remove the thread interface, because the SDK carries non-exception BEAM crash provenance there; retain only an SDK thread struct's validated identifier and rebuilt frames, and drop names, states, flags, held locks, malformed threads, and threads that are redundant with a rebuilt exception.
- Rebuild the SDK's nested `logger_metadata` extra from the curated `request_id`, `worker_model`, and `model_backend` allowlist so the Logger metadata contract is observable on the wire, and drop Logger level, domain, and every other nested key.
- Preserve only validated first-party repo-relative stack-frame filenames under `apps/<first-party-app>/lib/`, canonicalizing the BEAM app-relative `lib/` paths that real crashes carry only when the frame's module resolves through runtime OTP application ownership to an approved Orchard app; remove absolute, machine-specific, traversal, unknown, dependency-owned, and source URL paths, including path-shaped values placed in frame or exception names.
- Add static component, Product Version, Build Channel, Git SHA, and build-date tags plus a stable Sentry release identity for controller and Node Agent releases.
- Mark first-party OTP applications as in-app while explicitly keeping source-code context, both Sentry tracing configuration paths, Sentry Logs, client discard reports, and dependency inventory reporting disabled.
- Remove raw Orchard node IDs from Logger metadata and retain existing event deduplication and rate limiting.
- Add full-event, serialized-envelope, real local HTTP delivery, background-crash, and failure-isolation regression tests.
- Require controlled hosted-Sentry gates to retain default scrubbers, prevent IP-address storage, and remove anything from `$user.geo.**` before source-development or packaged events are sent.
- Keep Sentry optional and subordinate to `SPEC.md` §9 Prometheus, OpenTelemetry, and structured JSON log requirements.

## Capabilities

### New Capabilities

- `sentry-crash-reporting`: Defines Orchard's optional, data-minimized crash-event boundary, safe diagnostics, build provenance, and failure isolation.

### Modified Capabilities

- None.

## Impact

- SPEC.md impact: none. This change hardens an optional diagnostic integration without changing Orchard's normative observability architecture.
- Runtime impact: `config/runtime.exs` will derive static Sentry identity from the active release and canonical OTP Product Version.
- Controller impact: the endpoint will replace broad SDK request collection with an Orchard-owned method-only Plug.
- Shared impact: `Orchard.SentryFilter`, `Orchard.SentryLogger`, and a focused Sentry release-metadata helper will enforce the outbound contract for controller and Node Agent events.
- Test impact: focused tests will inspect final serialized envelopes and one real HTTP request delivered to a loopback-only local test endpoint.
- Operational impact: Orchard performs no automatic Sentry mutation. Explicitly authorized source-development and packaged smoke gates configure defense-in-depth project controls, send only synthetic events, inspect stored payloads, and delete any failed controlled issue before retrying.
