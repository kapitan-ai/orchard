## Context

Orchard installs the Sentry Logger handler only when `ORCHARD_SENTRY_DSN` is configured and uses `Orchard.SentryFilter.filter/1` as `before_send`. The filter recursively scrubs named keys but currently leaves structurally unknown request-body fields intact. The controller endpoint also installs `Sentry.PlugContext` after JSON parsing, so the SDK collects full URL and query data, most headers, request parameters, client address, server identity, and port data before the outbound callback runs.

Pinned Sentry Elixir 12.0.3 invokes `before_send` before `Sentry.Envelope.from_event/1`, making the callback the final in-process policy boundary. `Sentry.Envelope.to_binary/1` is the final serialization seam. The SDK also supports `in_app_otp_apps` without enabling source-code context and defaults Sentry Logs and tracing to disabled.

The authenticated Sentry project is currently a blank rollout target: it has no issues, environments, releases, additional sensitive fields, or advanced scrubbing rules. Project default data scrubbing is enabled, but project and organization IP-address prevention are disabled. Orchard therefore cannot treat server-side Sentry settings as its privacy boundary.

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
- Send a production or smoke event, mutate Sentry settings, resolve issues, or publish a Sentry release.
- Add raw request routes, request values, customer identity, machine identity, source snippets, dependency inventories, or hostnames for convenience.
- Change Product Version policy owned by the active `product-versioning-release-governance` change.

## Decisions

### Decision: Request Context Uses Collection And Egress Allowlists

The controller endpoint will install an Orchard-owned Plug that sets Sentry request context to `%{method: conn.method}` and nothing else. It will not call `Sentry.PlugContext`, fetch cookies, fetch query parameters, read headers, inspect parsed params, build a request URL, or inspect peer data.

`Orchard.SentryFilter` will independently reconstruct every top-level `request` interface, whether represented as a map or Sentry struct, with only a normalized safe HTTP method. Allowed methods are standard uppercase HTTP method tokens; invalid or non-binary values are omitted. All other request keys are removed rather than replaced with marker strings so the serialized envelope contains no structural copy of the body.

The collection allowlist minimizes process-local exposure. The egress allowlist protects events created outside Plug, future integrations, test fixtures, and accidental context changes. Retaining only one layer is rejected because collection-only protection does not cover synthetic or background events and filter-only protection retains sensitive values longer than necessary.

### Decision: Actual Sentry Events Use A Final Schema Allowlist

Request allowlisting alone cannot guarantee safe outbound events because Elixir exception values, event messages, breadcrumb text, unknown extras, contexts, and Logger metadata may contain inspected request terms or machine paths. `Orchard.SentryFilter` will therefore detect actual `Sentry.Event` structs without introducing a compile dependency and rebuild their payload from the SDK's empty struct shape.

The final event may retain validated event identity, environment, release, static and known Orchard tags, known Orchard enrichment extras, known Orchard breadcrumbs, a method-only request, exception type, and positively rebuilt stack frames. Exception values and event messages become fixed filtered markers. User data, unknown tags and extras, non-Orchard breadcrumbs, runtime contexts, dependency modules, threads, fingerprints, attachments, and source text are removed. Known enrichment values must pass validators selected by key rather than a shared printable-string check. Identifier-like fields reject path forms, URLs, IP addresses, free text, and malformed namespaces; booleans, counts, durations, dates, timestamps, build SHAs, fixed redaction markers, and Orchard correlation hashes retain explicit shape validation. Newly allowlisted keys default to filtered until assigned a validator.

`source` and `original_exception` may remain in memory because the SDK removes those fields before serialization and existing controlled-crash tests require them, but they are never envelope payload fields. Generic maps and non-Sentry structs continue through the existing recursive scrubber because Orchard also uses that helper for local CLI status sanitization.

If event rebuilding fails, the filter returns a valid minimal event containing only validated event identity, release/environment, a redacted server name, and a `sentry_filter_failed` marker. It does not return malformed interface values that could fail later during envelope serialization.

### Decision: First-Party Source Filenames Are Normalized, Not Blanket-Filtered

`filename` values in stack frames may survive only as normalized paths beginning with one of:

- `apps/orchard_controller/lib/`
- `apps/orchard_node_agent/lib/`
- `apps/orchard_shared/lib/`
- `apps/orchard_cli/lib/`

The filter may extract such a suffix from an absolute compiler path, but the absolute prefix never survives. The resulting path must use forward slashes, contain no empty, `.` or `..` segments, contain no NUL byte, and identify an Elixir source file. Unknown relative paths, dependency paths, `_build` paths, source URLs, and all absolute-path fields are filtered. Frame module/function values and exception type/module values use separate bounded Elixir diagnostic grammars so a crafted path cannot survive through a nominally non-path stack field.

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

### Decision: Wire Tests Inspect The Actual HTTP Body

Unit tests will first construct realistic full `Sentry.Event` values for Responses and Chat Completions payloads, pass them through `before_send`, serialize them with `Sentry.Envelope.to_binary/1`, and assert sentinel request values and machine paths are absent while safe identity remains. Controller and Node Agent Logger tests also serialize their captured background-crash events through the final filter, while the controller request-crash test proves approved hashes, license identity, and breadcrumb diagnostics survive that same boundary.

An integration test will start Bandit on loopback with port `0`, configure a local DSN and synchronous Sentry send, capture one controlled event, receive the actual request body in the Plug, and parse the envelope item JSON. The test will assert request method, relative first-party filename, release, environment, and static tags while rejecting prompts, instructions, tools, tool choices, metadata, headers, cookies, query values, client addresses, usernames, and absolute paths.

A local endpoint returning an error will verify that Sentry failure does not alter the calling process or request result. Existing no-DSN startup and Logger-handler tests remain part of the affected suite.

## Risks / Trade-offs

- Method-only request context loses URL and route grouping, but routes and URLs can contain sensitive or customer-controlled values; safe Orchard surface and lifecycle tags remain the preferred diagnostic dimensions.
- Extracting a known repo suffix from an absolute compiler path is more complex than filtering every filename, but it preserves actionable first-party location without machine identity.
- Disabling dependency inventory removes convenient library-version context, but Product Version, Git SHA, release identity, module, stack frames, and lockfile history provide a safer reconstruction path.
- Explicit defaults add configuration lines, but make the non-expansion policy reviewable during SDK upgrades.
- A real HTTP wire test is slower than a pure serializer test, so both are retained: serializer tests provide fast red/green feedback and one focused integration test proves transport bytes.

## Rollout Plan

1. Land the code and regression tests without configuring a real DSN.
2. Build the intended packaged controller and Node Agent artifacts.
3. Before controlled smoke events, enable project-level Sentry IP-address prevention while retaining default server scrubbers as defense in depth; do not rely on those settings for correctness.
4. Send one controlled controller crash and one controlled Node Agent crash from non-sensitive test flows.
5. Inspect Sentry event JSON and UI for release identity, static tags, first-party relative frames, and absence of disallowed request and machine data.
6. Resolve only the controlled smoke issues after the payload review succeeds.

Rollback removes the DSN or disables Sentry enrichment. Orchard continues through normative metrics, traces, and structured logs.
