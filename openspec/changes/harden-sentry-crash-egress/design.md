## Context

Orchard installs the Sentry Logger handler only when `ORCHARD_SENTRY_DSN` is configured and uses `Orchard.SentryFilter.filter/1` as `before_send`. The filter recursively scrubs named keys but currently leaves structurally unknown request-body fields intact. The controller endpoint also installs `Sentry.PlugContext` after JSON parsing, so the SDK collects full URL and query data, most headers, request parameters, client address, server identity, and port data before the outbound callback runs.

Pinned Sentry Elixir 12.0.3 invokes `before_send` before `Sentry.Envelope.from_event/1`, making the callback the final in-process policy boundary. `Sentry.Envelope.to_binary/1` is the final serialization seam. The SDK also supports `in_app_otp_apps` without enabling source-code context and defaults Sentry Logs and tracing to disabled.

At investigation start, the authenticated Sentry project was a blank rollout target with default data scrubbing enabled but project and organization IP-address prevention disabled. A controlled source-development preflight then confirmed Sentry derives `user.geo` from the ingest connection even when project-level IP-address storage prevention is enabled. Sentry documents that behavior and requires an Advanced Data Scrubbing rule that removes anything from `$user.geo.**` to suppress the derived geography. Orchard therefore requires both controls before any real smoke event, but still cannot treat server-side Sentry settings as its in-process privacy boundary.

## Goals / Non-Goals

**Goals:**

- Ensure unknown present and future inference request fields cannot leave Orchard through Sentry.
- Avoid collecting disallowed request values into Sentry context when a small allowlist can replace collection.
- Retain enough first-party stack and build identity to group, locate, and compare crashes.
- Keep controller and Node Agent startup, requests, and background processes independent of Sentry availability or transport failure.
- Exercise the exact serialized bytes accepted by a local HTTP endpoint.

**Non-Goals:**

- Enable Sentry tracing, profiling, replays, structured Logs, source-code attachments, source-code context, user feedback, or request performance monitoring.
- Replace Prometheus, OpenTelemetry, or structured JSON logs.
- Send production traffic, mutate Sentry automatically from Orchard, retain failed controlled-smoke issues, or publish a Sentry release through the implementation. Explicitly authorized source-development and packaged smoke gates remain operator-run rollout work.
- Add raw request routes, request values, customer identity, machine identity, source snippets, dependency inventories, or hostnames for convenience.
- Change Product Version policy owned by the active `product-versioning-release-governance` change.

## Decisions

### Decision: Request Context Uses Collection And Egress Allowlists

The controller endpoint will install an Orchard-owned Plug that sets Sentry request context to `%{method: conn.method}` and nothing else. It will not call `Sentry.PlugContext`, fetch cookies, fetch query parameters, read headers, inspect parsed params, build a request URL, or inspect peer data.

`Orchard.SentryFilter` will independently reconstruct every top-level `request` interface, whether represented as a map or Sentry struct, with only a normalized safe HTTP method. Allowed methods are standard uppercase HTTP method tokens; invalid or non-binary values are omitted. All other request keys are removed rather than replaced with marker strings so the serialized envelope contains no structural copy of the body.

The collection allowlist minimizes process-local exposure. The egress allowlist protects events created outside Plug, future integrations, test fixtures, and accidental context changes. Retaining only one layer is rejected because collection-only protection does not cover synthetic or background events and filter-only protection retains sensitive values longer than necessary.

### Decision: Actual Sentry Events Use A Final Schema Allowlist

Request allowlisting alone cannot guarantee safe outbound events because Elixir exception values, event messages, breadcrumb text, unknown extras, contexts, and Logger metadata may contain inspected request terms or machine paths. `Orchard.SentryFilter` will therefore detect actual `Sentry.Event` structs without introducing a compile dependency and rebuild their payload from the SDK's empty struct shape.

The final event may retain validated event identity, environment, release, static and known Orchard tags, known Orchard enrichment extras, known Orchard breadcrumbs, a method-only request, exception type, and positively rebuilt stack frames. Exception values and event messages become fixed filtered markers. User data, unknown tags and extras, non-Orchard breadcrumbs, runtime contexts, dependency modules, fingerprints, attachments, and source text are removed.

The pinned SDK deduplication hash omits the thread interface, so thread-only crashes at different sites would otherwise be indistinguishable and the second one would be discarded for the deduplication window. Rather than weakening deduplication or introducing custom grouping, the filter derives an `orchard_thread_stack_hash` extra from the frames it already transmits: a SHA-256 over the retained module, function, canonical filename, and line number values, truncated to 16 lowercase hexadecimal characters. It discloses nothing beyond the sanitized frames, is never accepted from a caller, is absent for exception-backed and frameless events, and leaves genuine same-site repeats deduplicating as before. A fingerprint was rejected because it would also override Sentry grouping.

That reasoning does not extend to frameless non-exception events, which the SDK Logger error backend also produces: a `%{reason: reason}` report with no stacktrace becomes a message event with no exception and no threads. After filtering, such an event has a fixed filtered message, an empty fingerprint, static tags, and no retained frames, so every input to the pinned deduplication hash is constant across them. Otherwise-identical frameless events therefore share one opaque hosted issue and may collapse inside the 30-second SDK deduplication window. That bounded loss of occurrence count is accepted rather than repaired, because no safe distinguishing provenance survives the egress allowlist: a nonce or a hash of the raw message or crash reason would leak or re-encode free-form content, a fingerprint would override Sentry grouping, retaining the SDK's Logger domain and level extras would broaden the schema, and parsing a free-form crash report is exactly the input this change exists to remove. Any future subdivision must use a separately approved bounded enumeration derived from trusted structured crash data.

The thread interface is rebuilt instead of removed. The pinned SDK reports non-exception BEAM crashes — bad GenServer return values, exits, and `GenServer.call` timeouts — as message events whose only stack provenance lives under `threads`, so removing it left a large class of crashes with no message, no frames, and no grouping signal. Threads survive only for events with no rebuilt exception, only from actual SDK thread structs, and only when an actual SDK stacktrace struct yields at least one rebuilt frame. Retained threads carry a validated SDK thread identifier, or a fixed non-sensitive identifier the interface requires, plus the rebuilt stacktrace; names, states, crashed/current/main flags, held locks, locals, source context, and unknown fields are dropped. A map-shaped stacktrace supplied by non-SDK compatibility input may be reduced to a frames-only map only where the pinned renderer safely omits that unsupported non-struct interface before serialization.

Every rebuilt interface container is gated on exact pinned SDK module identity, resolved by comparing the value's split module path against the interface path rather than by compiling against Sentry. The message, exception, breadcrumb, request, thread, stacktrace, and stack-frame paths all use the same gate, so the invariant is enforced symmetrically instead of only on threads. A foreign struct that merely exposes the same field names is dropped, not rebuilt as its own module, for two reasons: rebuilding started from that module's own defaults, which could carry sentinel values straight into the envelope, and the pinned renderer pattern-matches the interface structs exactly, so a foreign exception, message, or thread module would raise inside `Sentry.Envelope.to_binary/1` — past the filter's rescue, where the fail-closed path can no longer run. Generic maps and non-Sentry structs are untouched by these gates and keep the recursive denylist scrub used for local CLI status snapshots.

Curated Logger metadata is also rebuilt rather than assumed to be top level. The SDK nests it as an `extra.logger_metadata` map alongside its own Logger level and domain entries, so a top-level allowlist alone never matched it and the curated handler metadata list had no observable outbound effect. Only a plain-map container is recognized, only `request_id`, `worker_model`, and `model_backend` are rebuilt through their existing typed validators, and an absent, non-map, or empty container is omitted. Known enrichment values must pass validators selected by key rather than a shared printable-string check. Identifier-like fields reject path forms, URLs, IP addresses, free text, and malformed namespaces; booleans, counts, durations, dates, timestamps, build SHAs, fixed redaction markers, and Orchard correlation hashes retain explicit shape validation. Newly allowlisted keys default to filtered until assigned a validator.

`source` and `original_exception` may remain in memory because the SDK removes those fields before serialization and existing controlled-crash tests require them, but they are never envelope payload fields. Generic maps and non-Sentry structs continue through the existing recursive scrubber because Orchard also uses that helper for local CLI status sanitization.

If event rebuilding fails, the filter returns a valid minimal event containing only validated event identity, release/environment, a redacted server name, and a `sentry_filter_failed` marker. It does not return malformed interface values that could fail later during envelope serialization.

### Decision: First-Party Source Filenames Are Normalized, Not Blanket-Filtered

`filename` values in stack frames may survive only as normalized paths beginning with one of:

- `apps/orchard_controller/lib/`
- `apps/orchard_node_agent/lib/`
- `apps/orchard_shared/lib/`
- `apps/orchard_cli/lib/`

Three normalization inputs may produce such a path, and no other input may:

1. A path that already begins with one of those approved roots.
2. An absolute compiler path from which the filter extracts an approved-root suffix. The absolute prefix never survives.
3. A BEAM app-relative `lib/...` path, which is the shape real Orchard stacktraces carry because the compiled `-file` attribute in this umbrella is relative to each app directory. The filter canonicalizes it to `<approved-root>...` only when the frame's own `module` value resolves through runtime OTP application ownership to `:orchard_controller`, `:orchard_node_agent`, `:orchard_shared`, or `:orchard_cli`.

Input 3 exists because inputs 1 and 2 never match a real first-party production frame, which would leave the entire retention branch dead. Ownership is read from the module value already present on the frame; the filter never converts a string to an atom to obtain it, so a caller cannot fabricate ownership through a crafted module name. Frames whose module is absent, `nil`, a string, unloaded, unowned, or owned by a dependency or non-approved application resolve to no root and keep their filename filtered. Deterministic-build basenames such as `licensing.ex` carry no `lib/` prefix and stay filtered for the same reason.

Canonicalization is a prefix rewrite only; the rewritten path is then subject to the same validation as every other input. The resulting path must use forward slashes, contain no empty, `.` or `..` segments, contain no NUL byte, identify an Elixir source file, and begin with one of the four approved roots. Output therefore stays bounded to the approved roots and the safe path grammar regardless of which input produced it. Unknown relative paths, dependency paths, `_build` paths, source URLs, and all absolute-path fields that yield no approved suffix are filtered. Frame module/function values and exception type/module values use separate bounded Elixir diagnostic grammars so a crafted path cannot survive through a nominally non-path stack field.

Source-code context remains disabled, so source lines and neighboring source text are not attached. `in_app_otp_apps` names the four first-party OTP apps so Sentry can emphasize Orchard frames without exposing source content.

### Decision: Static Release Identity Covers Background Events

A shared release-metadata helper will map `RELEASE_NAME` or `MIX_RELEASE_NAME` to a stable component value and derive Product Version from loaded `:orchard_shared` OTP application metadata, which already derives from root `VERSION`. Build provenance continues to come from `Orchard.BuildInfo`.

Controller and Node Agent packaged releases will emit:

- Sentry release: `<release-name>@<product-version>+<short-git-sha>`
- `orchard_app`: `controller` or `node_agent`
- `orchard_version`: the canonical Product Version
- `orchard_build_channel`: `Orchard.BuildInfo.build_channel/0`
- `build_sha`: `Orchard.BuildInfo.git_sha/0`
- `build_date`: `Orchard.BuildInfo.build_date/0`

Unknown source-development release names remain explicit rather than being mislabeled as packaged controller or Node Agent events. Static configuration ensures Logger-captured background crashes receive identity even when no request context exists.

### Decision: SDK Diagnostics Stay Narrow And Explicit

Sentry configuration will explicitly keep `enable_logs: false`, `enable_source_code_context: false`, `traces_sample_rate: nil`, `traces_sampler: nil`, and `report_deps: false`. Event deduplication remains enabled. The Logger metadata allowlist will remove raw `orchard_node_id`; hashed node correlation remains available through Orchard-owned enrichment where configured.

No source snippets, dependency inventory, tracing spans, transaction events, or Sentry Logs are added. These settings are explicit so a future SDK default change cannot silently broaden the rollout.

### Decision: Hosted Sentry Must Remove Server-Derived Geography

Sentry derives geographic fields from the ingest connection even when project-level IP-address storage prevention is enabled. This augmentation occurs after Orchard's envelope has left the process, so `Orchard.SentryFilter` cannot remove it. Before any controlled source-development or packaged smoke event, the target project must therefore retain default server scrubbers, enable IP-address storage prevention, and apply an Advanced Data Scrubbing rule that removes anything from `$user.geo.**`.

These hosted controls are defense in depth and a post-ingest augmentation guard, not substitutes for Orchard's collection and egress allowlists. A smoke review must inspect the stored event rather than only the outbound envelope. If a controlled event contains server-derived geography or any other disallowed field, the sender removes the DSN, deletes the affected controlled issue because new scrubbing rules are not retroactive, corrects the project policy or Orchard boundary, and sends no replacement until the correction is verified.

### Decision: Wire Tests Inspect The Actual HTTP Body

Unit tests will first construct realistic full `Sentry.Event` values for Responses and Chat Completions payloads, pass them through `before_send`, serialize them with `Sentry.Envelope.to_binary/1`, and assert sentinel request values and machine paths are absent while safe identity remains. Controller and Node Agent Logger tests also serialize their captured background-crash events through the final filter, while the controller request-crash test proves approved hashes, license identity, and breadcrumb diagnostics survive that same boundary.

An integration test will start Bandit on loopback with port `0`, configure a local DSN and synchronous Sentry send, capture one controlled event, receive the actual request body in the Plug, and parse the envelope item JSON. The test will assert request method, relative first-party filename, release, environment, and static tags while rejecting prompts, instructions, tools, tool choices, metadata, headers, cookies, query values, client addresses, usernames, and absolute paths.

A local endpoint returning an error will verify that Sentry failure does not alter the calling process or request result. Existing no-DSN startup and Logger-handler tests remain part of the affected suite.

Hosted Sentry currently omits a method-only request interface from its stored event even though the serialized Orchard envelope is valid and contains `request.method`. The envelope remains the evidence for Orchard's collection and egress contract. Orchard does not add a fabricated URL to influence hosted normalization; making the method separately queryable would require a future, explicitly approved diagnostic-schema change.

## Risks / Trade-offs

- Method-only request context loses URL and route grouping, but routes and URLs can contain sensitive or customer-controlled values; safe Orchard surface and lifecycle tags remain the preferred diagnostic dimensions.
- Extracting a known repo suffix from an absolute compiler path is more complex than filtering every filename, but it preserves actionable first-party location without machine identity.
- Disabling dependency inventory removes convenient library-version context, but Product Version, Git SHA, release identity, module, stack frames, and lockfile history provide a safer reconstruction path.
- Explicit defaults add configuration lines, but make the non-expansion policy reviewable during SDK upgrades.
- A real HTTP wire test is slower than a pure serializer test, so both are retained: serializer tests provide fast red/green feedback and one focused integration test proves transport bytes.
- Hosted Sentry privacy settings are mutable external state and cannot be covered by the local envelope tests, so every real smoke gate must re-verify IP prevention and `$user.geo.**` removal before sending.
- Frameless non-exception crashes lose per-crash occurrence counts because they deduplicate into one opaque hosted issue; the trade is accepted so that free-form crash reasons stay out of the envelope, and thread-backed crashes, which are the larger class, still separate through `orchard_thread_stack_hash`.
- Gating interface rebuilding on exact SDK module identity means an SDK upgrade that renames or moves an interface module silently drops that container rather than emitting a wrong shape. Envelope tests over real SDK structs fail loudly if that happens, which is the intended direction to fail.

## Rollout Plan

1. Complete the local serializer, loopback HTTP, Logger-capture, and failure-isolation regression suite without configuring a real DSN.
2. Before any real event, retain default server scrubbers, enable project-level IP-address storage prevention, and apply the Advanced Data Scrubbing rule `[Remove] [Anything] from [$user.geo.**]`.
3. From the exact pull-request head in a non-sensitive source-development environment, send one controlled controller crash and one controlled Node Agent crash using only synthetic canaries.
4. Inspect the stored Sentry event JSON and UI for release identity, static tags, first-party relative frames, empty source context, and complete absence of disallowed request, user, machine, IP, and geographic data. Delete any failed controlled issue before correcting and repeating the gate; resolve only clean controlled issues.
5. Land the reviewed code and regression tests only after the source-development gate succeeds.
6. Build the intended packaged controller and Node Agent artifacts from the landed commit.
7. Re-verify the hosted controls, send one controlled packaged crash per role, and repeat the stored-event review without treating the source-development result as packaged evidence.
8. Resolve only the clean packaged smoke issues after the payload review succeeds, then decide whether to remove the DSN or continue on selected internal hosts.

Rollback removes the DSN or disables Sentry enrichment. Orchard continues through normative metrics, traces, and structured logs.
