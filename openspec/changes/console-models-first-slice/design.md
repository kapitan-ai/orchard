## Context

ModelsLive owns the catalog and ModelHubLive owns asynchronous discovery and coordinator-backed imports.
The importer re-fetches provider metadata after the operator selects a model, so provider-head drift can otherwise change the selected artifact or combine metadata from different snapshots.

## Goals / Non-Goals

Deliver a real catalog and discovery journey using existing LiveViews, components, and services.
Preserve lifecycle operations, background import recovery, and existing authorization.
Workspace terminology migration, new access flows, historical revision browsing, and runtime placement changes are outside this change.

## Decisions

Use shared Models navigation and a canonical discovery route while keeping the old URL as a compatibility entry.
This preserves existing links and avoids duplicating catalog or discovery services.
Import advances from Discover models to a distinct Catalog step within the existing LiveView.
The Catalog step replaces discovery content, carries exact identity, and keeps provider details subordinate to the import action and result.
Back preserves discovery assigns and returns focus to the originating action; background coordinator jobs continue independently.
This is a presentation change under SPEC.md sections 6.5 and 10.2, with no new import, access, or runtime semantics.

Capability controls explicitly filter the returned provider results, with unknown metadata kept distinct.
They do not certify Orchard runtime support.

Pass the revision from server-held detail assigns, ignoring client-supplied revision parameters.
Compare it with freshly fetched provider detail before downloading.
If they differ, fail with a refresh-and-reselect explanation, since the current provider client cannot fetch a coherent historical detail snapshot.
Overwriting newer metadata with an older revision would give a false identity guarantee; adding historical provider browsing is unnecessary for this journey.

Use the stored catalog record as the source of the final bundle digest.
Keep catalog activation separate from Node and request readiness in the completion copy.
Follow docs/DESIGN.md components and tokens, including explicit focus states and scroll ownership.

## Risks / Trade-offs

Provider updates between inspection and import cause a recoverable failure.
Operators must refresh and select the new revision.
Filtering covers the returned result set, so the UI must name this scope.
Existing Model Hub URLs continue to work and show the Models navigation.

## Migration Plan

No database migration is required.
Deploy the route, navigation, pipeline check, and UI together.
Rollback is a code rollback; imported records retain the existing schema and lifecycle.
## Hardware-aware discovery boundary

Discovery displays the full six-step journey with future steps disabled and labels the first step Discover models.
Node inventory is read once asynchronously per connected mount; failures remain distinct from an empty installation.
Provider cards expose unverified Node fit until exact artifact requirements and hardware evidence are available.
The current Node inventory reports backend capabilities but does not expose physical memory or chip specifications.
The normal heartbeat persistence path does not populate the available-memory column.
Implementing positive fit estimates requires a separate telemetry and model-requirement change under SPEC section 5.5, including load memory, prefill workspace, KV growth, and safety margin.
Repository storage and stored parameter counts must not substitute for those runtime requirements.

## Download lifecycle controls

The coordinator owns a per-job control signal and serializes controls against a synchronous pre-import phase gate.
The downloader checks controls at file boundaries and incoming HTTP chunks.
Pause halts and closes the HTTP stream, then waits outside the request with the same worker, validated metadata, temporary directory, and completed-file reduction state.
Resume retries only the interrupted file through existing ETag and Range validation.
Cancel returns through the ordinary pipeline cleanup before a terminal snapshot is broadcast.
Bundle preparation and Catalog import are non-interruptible because artifact staging, final rename, and Catalog insertion must preserve SPEC.md section 6.5.
The coordinator retains job snapshots only for the current Controller process lifetime.

## Direct Catalog

Models opens the unified Catalog at `/console/models`, with `/console/models/catalog` as an alias and Discover as its peer destination.
Catalog distinguishes durable imported records from Controller-session import activity, including paused, cancelled, and failed attempts.
Pending attempts are not synthetic persisted Model records.
An activity link carries a repository and revision lookup key which must match a server-held coordinator job before detail or controls are exposed.
Catalog-origin detail returns to Catalog; Discover-origin setup retains its existing search return behavior.

