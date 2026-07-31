## ADDED Requirements

### Requirement: Optional Sentry Request Data Is Allowlisted

When optional Sentry crash reporting is configured, Orchard SHALL collect and transmit only the normalized HTTP method from request context. Orchard SHALL NOT collect into Sentry context or transmit request bodies, headers, cookies, URLs, route values, query strings, client addresses, server addresses, ports, user data, or other request fields. The outbound filter SHALL reconstruct request interfaces from the allowlist regardless of event source or map-versus-struct representation. This requirement hardens optional diagnostics beneath `SPEC.md` §9 without making Sentry normative.

#### Scenario: Responses request contains proprietary inference data

- **WHEN** a `/v1/responses` crash event contains input, instructions, tools, tool choice, metadata, headers, cookies, URL query data, or client address data
- **THEN** the serialized Sentry envelope contains none of those values or fields and may contain only the normalized HTTP method in its request interface

#### Scenario: Compatibility request contains an unknown future field

- **WHEN** a `/v1/chat/completions` or future API request contains a body field not named by Orchard's sensitive-key denylist
- **THEN** the field is absent because the request interface is reconstructed from an allowlist rather than scrubbed field by field

#### Scenario: Event request interface uses a Sentry struct

- **WHEN** the SDK supplies request context as a struct instead of a plain map
- **THEN** Orchard preserves the valid struct shape while retaining only the allowed method and serializes no disallowed request value

### Requirement: Outbound Sentry Events Use A Final Schema Allowlist

Orchard SHALL rebuild actual Sentry event payloads from an allowlist after collection and before envelope serialization. Orchard SHALL replace free-form event messages and exception values with fixed filtered markers and SHALL remove unknown extras, unknown tags, non-Orchard breadcrumbs, user data, contexts, dependency modules, threads, fingerprints, attachments, and source text. Orchard MAY retain validated event identity, environment, release/build identity, known Orchard tags and enrichment, method-only request context, exception type, and positively rebuilt stack frames. Any known enrichment value that survives SHALL be a bounded JSON scalar that passes a semantic validator for its key. Identifier fields SHALL reject absolute or machine-path forms, URLs, IP addresses, whitespace-bearing free text, and malformed namespaces; booleans, counts, durations, dates, timestamps, hashes, and fixed redaction markers SHALL pass their corresponding shape validation.

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
