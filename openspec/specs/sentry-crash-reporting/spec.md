# sentry-crash-reporting Specification

## Purpose
Define privacy-preserving, allowlisted crash-reporting behavior for Orchard's optional Sentry integration.

## Requirements
### Requirement: Optional Sentry Request Data Is Allowlisted

When optional Sentry crash reporting is configured, Orchard SHALL collect and transmit only the normalized HTTP method from request context. Orchard SHALL NOT collect into Sentry context or transmit request bodies, headers, cookies, URLs, route values, query strings, client addresses, server addresses, ports, user data, or other request fields. No disallowed request value SHALL egress on either outbound scrubbing path, whatever representation it arrives in. For an actual Sentry event payload, Orchard SHALL retain request context only when the container is the exact pinned SDK-native request interface struct, SHALL rebuild it from the allowlist with the normalized HTTP method alone, and SHALL omit an absent, bare-map, foreign-struct, malformed, or otherwise unsupported request container entirely rather than emitting a substitute container. For the generic map and non-Sentry struct scrubbing Orchard reuses for CLI and local compatibility snapshots, Orchard SHALL reduce a map-shaped request value to at most its normalized HTTP method and SHALL remove every other request field. This requirement hardens optional diagnostics beneath `SPEC.md` §9 without making Sentry normative.

#### Scenario: Responses request contains proprietary inference data

- **WHEN** a `/v1/responses` crash event contains input, instructions, tools, tool choice, metadata, headers, cookies, URL query data, or client address data
- **THEN** the serialized Sentry envelope contains none of those values or fields and may contain only the normalized HTTP method in its request interface

#### Scenario: Compatibility request contains an unknown future field

- **WHEN** a `/v1/chat/completions` or future API request contains a body field not named by Orchard's sensitive-key denylist
- **THEN** the field is absent because the request interface is reconstructed from an allowlist rather than scrubbed field by field

#### Scenario: Event request interface uses a Sentry struct

- **WHEN** the SDK supplies request context as a struct instead of a plain map
- **THEN** Orchard preserves the valid struct shape while retaining only the allowed method and serializes no disallowed request value

#### Scenario: Actual event carries an unsupported request container

- **WHEN** an actual Sentry event's request value is absent, a bare map, a foreign struct, or otherwise not the pinned SDK-native request interface struct, and it carries request body, header, or address data
- **THEN** the serialized envelope omits the request interface entirely instead of emitting a substitute method-only container, and none of that request data appears anywhere in the envelope

#### Scenario: Compatibility scrubbing reduces a request map

- **WHEN** generic map or non-Sentry struct scrubbing, such as a local CLI status snapshot, encounters a `request` value carrying a method alongside other request fields
- **THEN** Orchard retains at most the normalized HTTP method in that value and removes every other request field

### Requirement: Outbound Sentry Events Use A Final Schema Allowlist

Orchard SHALL rebuild actual Sentry event payloads from an allowlist after collection and before envelope serialization. Orchard SHALL replace free-form event messages and exception values with fixed filtered markers and SHALL remove unknown extras, unknown tags, non-Orchard breadcrumbs, user data, contexts, dependency modules, fingerprints, attachments, and source text. Orchard MAY retain validated event identity, environment, release/build identity, known Orchard tags and enrichment, method-only request context, exception type, and positively rebuilt stack frames. Any known enrichment value that survives SHALL be a bounded JSON scalar that passes a semantic validator for its key. Identifier fields SHALL reject absolute or machine-path forms, URLs, IP addresses, whitespace-bearing free text, and malformed namespaces; booleans, counts, durations, dates, timestamps, hashes, and fixed redaction markers SHALL pass their corresponding shape validation.

Because the SDK reports non-exception BEAM crashes as message events whose only stack provenance lives in the thread interface, Orchard SHALL rebuild threads rather than removing them outright. Orchard SHALL retain a thread only when the event has no rebuilt exception, the value is an actual SDK thread struct, and its stacktrace is an actual SDK stacktrace struct that yields at least one rebuilt frame; every other thread SHALL be dropped. A retained thread SHALL carry only a validated SDK thread identifier, replaced by a fixed non-sensitive identifier when the supplied value is not a valid one, and its rebuilt stacktrace. Thread names, states, crashed/current/main flags, held locks, local variables, source context, and unknown fields SHALL be removed.

Rebuilt message, exception, breadcrumb, thread, stacktrace, thread-stacktrace, request, and stack-frame containers SHALL be the interface structs the pinned renderer requires, never bare maps and never a foreign struct module. Orchard SHALL identify each container by exact pinned SDK module identity and SHALL drop a container whose module is not the required interface rather than rebuilding it as its own module, so foreign struct defaults cannot reach the envelope and cannot raise inside envelope serialization beyond the filter's own fail-closed boundary. Orchard MAY still reduce a map-shaped stacktrace supplied by non-SDK compatibility input to a frames-only map, because the pinned renderer omits that unsupported non-struct interface before serialization rather than emitting it. Generic-map and non-Sentry struct scrubbing used for local CLI status snapshots is unaffected by these interface-identity gates.

The pinned SDK deduplication hash covers the exception, message, level, fingerprint, user, tags, extra, breadcrumbs, request, and attachment interfaces but not threads, so two different thread-only crash sites would otherwise collapse into one deduplicated event. For an event with no rebuilt exception and at least one retained thread frame, Orchard SHALL therefore derive an `orchard_thread_stack_hash` extra as the first 16 lowercase hexadecimal characters of a SHA-256 digest over a deterministic encoding of only the retained frame module, function, canonical filename, and line number values in retained frame order. Orchard SHALL compute that value internally after rebuilding threads and sanitizing extras, SHALL NOT accept or retain a caller-supplied value under that key, and SHALL omit the key entirely for exception-backed events and events with no retained thread frames. The derived value SHALL NOT be used as a Sentry fingerprint or grouping override, event deduplication SHALL remain enabled, and repeated crashes at the same sanitized stack SHALL still deduplicate within the SDK window.

Frameless non-exception events carry no retained stack provenance, so Orchard accepts that otherwise-identical frameless events share one opaque hosted issue and MAY collapse within the SDK deduplication window. Orchard SHALL NOT subdivide them with a nonce, a fingerprint, a hash or HMAC of the raw message or crash reason, retained SDK Logger domain or level extras, or any parse of a free-form crash report, because no safe distinguishing provenance survives the egress allowlist. Any future subdivision SHALL use a separately approved bounded enumeration derived from trusted structured crash data.

Curated Logger metadata reaches events nested inside a `logger_metadata` extra rather than at the top level. Orchard SHALL rebuild that container only when it is a plain map, SHALL retain only `request_id`, `worker_model`, and `model_backend` values that pass their existing typed validators, and SHALL omit the container entirely when it is absent, not a map, or empty after rebuilding. Orchard SHALL NOT retain the SDK's Logger level or domain extras or any other nested Logger metadata key.

#### Scenario: Non-exception OTP crash reaches Sentry as a message event

- **WHEN** a supervised process terminates for a non-exception reason and the SDK Logger handler reports it as a message event whose stack frames live in the thread interface
- **THEN** the serialized envelope retains the rebuilt thread stack frames as crash provenance while containing no thread name, state, held locks, GenServer state, last message, crash reason, or other unknown extra

#### Scenario: Event carries hostile, malformed, or redundant threads

- **WHEN** an event carries bare-map threads, foreign-struct threads, threads whose stacktrace is missing, foreign, or yields no rebuilt frames, or threads alongside a rebuilt exception
- **THEN** Orchard drops those threads, keeps a fixed non-sensitive identifier for any retained thread with an invalid identifier, and the envelope still serializes

#### Scenario: Two different processes crash without exceptions inside the deduplication window

- **WHEN** two background processes terminate for different non-exception reasons at different sanitized stack sites within the SDK deduplication window and neither event carries request enrichment
- **THEN** each event carries its own derived `orchard_thread_stack_hash` extra, the pinned SDK deduplication hash differs, and both crash stacks reach Sentry while a genuine repeat at the same sanitized stack still deduplicates

#### Scenario: Two frameless non-exception events arrive inside the deduplication window

- **WHEN** two background processes terminate for different non-exception reasons, both events reach the filter with no exception, no thread frames, and no other differing approved field, and the raw crash reasons differ only inside the free-form message and unallowlisted extras
- **THEN** Orchard removes both raw reasons, emits no `orchard_thread_stack_hash`, and the two filtered events share one pinned SDK deduplication hash, so they share one opaque hosted issue and the second may be discarded within the deduplication window as an accepted bounded loss of occurrence count

#### Scenario: Event carries foreign interface structs

- **WHEN** an event's message, exception, breadcrumb, request, stacktrace, or stack-frame value is a non-SDK struct that exposes the same field names and carries sentinel-valued struct defaults
- **THEN** Orchard drops that container instead of rebuilding its module, no sentinel default reaches the serialized envelope bytes, envelope serialization does not raise, and valid SDK interface values in the same event still rebuild and serialize

#### Scenario: Caller supplies a thread stack hash extra

- **WHEN** an event arrives with a caller-populated `orchard_thread_stack_hash` extra under any key form, with or without retained thread frames
- **THEN** Orchard drops the supplied value, emits only an internally derived 16-character lowercase hexadecimal value when the event has retained thread frames, and omits the key otherwise

#### Scenario: Crash carries curated Logger metadata

- **WHEN** a crash is captured with `request_id`, `worker_model`, `model_backend`, and raw node identity in Logger metadata
- **THEN** the serialized envelope contains only the three validated curated values inside the rebuilt `logger_metadata` extra and contains no raw node identity, Logger level, domain, or other metadata key

#### Scenario: Exception context contains inspected request data

- **WHEN** an exception value, event message, breadcrumb, context, unknown extra, or unknown tag contains a prompt, tool definition, credential, client identity, absolute path, or other request sentinel
- **THEN** the serialized envelope contains none of those values while retaining exception type, safe stack frames, and approved Orchard diagnostics

#### Scenario: Allowed field contains a malformed value

- **WHEN** an otherwise allowed tag, extra, or breadcrumb datum contains a PID, function, tuple, oversized string, control character, malformed correlation hash, path-shaped identifier, URL, IP address, or free-form text where a typed diagnostic value is required
- **THEN** Orchard replaces or removes the value before envelope serialization and Sentry cannot disclose it or turn it into a transport-side serialization failure

### Requirement: Sentry Stack Diagnostics Exclude Machine And Source Content

Orchard SHALL remove absolute paths, machine-specific paths, source URLs, dependency paths, build paths, traversal paths, and source-code context from Sentry events. Orchard MAY retain an Elixir source filename only after normalizing it to a validated repo-relative path under `apps/orchard_controller/lib/`, `apps/orchard_node_agent/lib/`, `apps/orchard_shared/lib/`, or `apps/orchard_cli/lib/`. Normalization MAY take a path that already begins with an approved root, an approved-root suffix extracted from an absolute compiler path, or a BEAM app-relative `lib/` path canonicalized to the approved root of the application that owns the frame. Ownership SHALL be resolved at runtime from the frame's existing module value through OTP application ownership and SHALL be accepted only for `orchard_controller`, `orchard_node_agent`, `orchard_shared`, and `orchard_cli`; Orchard SHALL NOT create atoms to resolve ownership. Every normalized path SHALL still satisfy the approved-root prefix, Elixir source extension, and no-traversal path grammar, so retained output remains bounded to the approved roots. Retained frame module/function names and exception names SHALL pass bounded Elixir diagnostic grammars so path-shaped values cannot use those fields as alternate egress channels. Orchard SHALL mark first-party OTP applications as in-app without attaching source lines or neighboring source text.

#### Scenario: Packaged stack frame contains an absolute compiler path

- **WHEN** a stack frame filename contains a machine-specific absolute prefix followed by a valid first-party Orchard app `lib/` path
- **THEN** the serialized event contains only the validated repo-relative suffix and no absolute prefix, username, home directory, or file URL

#### Scenario: Real crash frame carries a BEAM app-relative source path

- **WHEN** a real Orchard crash produces a frame whose filename is an app-relative `lib/` Elixir source path and whose module resolves at runtime to an approved first-party Orchard OTP application
- **THEN** the serialized event contains that path canonicalized to the owning application's approved `apps/<app>/lib/` root and no other path content

#### Scenario: App-relative frame is not owned by an approved application

- **WHEN** a frame carries an app-relative `lib/` path but its module is absent, is not an atom, is unloaded, or resolves to a dependency or any other non-approved application
- **THEN** Orchard filters the filename and transmits no path content from that field

#### Scenario: Stack frame path is unsafe or unrelated

- **WHEN** a frame path contains traversal, `_build`, a dependency root, an unknown app, a non-Elixir source target, a deterministic-build bare basename, or neither a valid first-party suffix nor approved module ownership
- **THEN** Orchard filters the filename and transmits no path content from that field

### Requirement: Every Sentry Crash Has Static Orchard Build Identity

For packaged controller and Node Agent releases, Orchard SHALL set static Sentry identity independent of process-local request enrichment. Each event SHALL identify the Orchard component, canonical Product Version, Build Channel, Git SHA, build date, environment, and a release string formatted as `<release-name>@<product-version>+<short-git-sha>`. Product Version SHALL derive from first-party OTP metadata governed by root `VERSION`, while Build Provenance SHALL remain separate.

#### Scenario: Background process crashes without request context

- **WHEN** a controller or Node Agent background process crashes before or outside HTTP request enrichment
- **THEN** its Sentry event still contains component, Product Version, Build Channel, Git SHA, build date, environment, and release identity

#### Scenario: Build has no Git provenance

- **WHEN** a build produces no Git SHA or build date and Orchard falls back to its readable `unknown` provenance sentinel
- **THEN** the outbound filter retains that exact sentinel in the build tags so missing provenance stays distinguishable from rejected provenance, while every other malformed SHA or date value is still filtered

#### Scenario: Source-development release name is unknown

- **WHEN** Sentry is explicitly enabled without a packaged controller or Node Agent release name
- **THEN** Orchard labels the component as an explicit development or unknown value and does not misclassify it as a packaged role

### Requirement: Optional Sentry Telemetry Does Not Broaden Observability

Orchard SHALL keep Sentry Logs, tracing, performance transactions, source-code context, client discard reports, and dependency inventory reporting disabled for this crash-reporting integration, including explicit nil values for both the trace sample rate and trace sampler. Logger capture SHALL exclude raw Orchard node IDs, SHALL retain its existing metadata allowlist and rate limit, and SHALL capture error events rather than ordinary log messages. Event deduplication SHALL remain enabled.

#### Scenario: Sentry DSN is configured

- **WHEN** Orchard enables optional Sentry crash reporting through a DSN
- **THEN** it enables error-event delivery without enabling logs, traces, source context, dependency inventory, raw node metadata, or request telemetry

#### Scenario: Sentry DSN is absent

- **WHEN** no Sentry DSN is configured
- **THEN** Orchard installs no Sentry Logger handler and performs no Sentry transport work

### Requirement: Controlled Hosted-Sentry Rollout Removes Server-Derived User Data

Before any controlled source-development or packaged event is sent to hosted Sentry, the rollout operator SHALL verify that default server scrubbers remain enabled, project-level IP-address storage prevention is enabled, and an Advanced Data Scrubbing rule removes anything from `$user.geo.**`. Orchard SHALL continue to enforce its in-process collection and egress allowlists independently because hosted controls are defense in depth and Sentry derives geographic user fields after ingest even when IP storage is disabled. Source-development validation SHALL precede merge, and packaged validation SHALL still repeat the stored-event review from the landed artifact.

#### Scenario: Hosted Sentry derives geography from the ingest connection

- **WHEN** a controlled event reaches Sentry with IP-address storage prevention enabled
- **THEN** the stored event contains neither an IP address nor derived `user.geo` data because the project also removes anything from `$user.geo.**`

#### Scenario: Stored smoke event contains disallowed server-derived data

- **WHEN** stored-event inspection finds geography or any other disallowed field that was added or retained after Orchard transmitted the envelope
- **THEN** the operator removes the DSN, deletes the affected controlled issue, corrects the project policy or Orchard boundary, and sends no replacement event until the correction is verified

### Requirement: Sentry Failure Cannot Block Orchard Work

Sentry filtering, handler installation, serialization, queueing, and transport failure SHALL fail closed for payload disclosure and SHALL NOT prevent controller or Node Agent startup, terminate the reporting caller, or change an API request's Orchard result. Regression coverage SHALL inspect final serialized envelope bytes and at least one real HTTP body delivered to a loopback-only local endpoint.

#### Scenario: Local Sentry receiver rejects an event

- **WHEN** a test receiver returns an error or the Sentry transport cannot deliver an event
- **THEN** the calling Orchard process remains alive or completes with its original result and the failure is diagnostic only

#### Scenario: Wire-level regression test captures an envelope

- **WHEN** a controlled event is sent synchronously to the loopback test receiver
- **THEN** the received envelope retains approved release and stack diagnostics while containing no proprietary request sentinel, credential, address, user, hostname, or absolute path
