## ADDED Requirements

### Requirement: Models navigation and recoverable discovery

The Console SHALL provide Catalog and Discover beneath one Models navigation entry and retain the existing Model Hub URL.
It SHALL distinguish empty catalogs, no matching results, provider failures, and denied access.
Filters SHALL identify their scope as returned provider results and SHALL NOT imply verified runtime support.

#### Scenario: Empty catalog
- **WHEN** the catalog contains no models
- **THEN** Catalog offers Discover and explains the existing offline bundle import path

#### Scenario: Restrictive filter
- **WHEN** a capability filter excludes all returned results
- **THEN** discovery shows no matching results and offers a way to clear the filter

#### Scenario: Provider failure
- **WHEN** provider search fails
- **THEN** discovery displays an error and a retry action rather than reporting an empty catalog

### Requirement: Selected snapshot controls import

Consistent with SPEC.md section 6.5, the Console SHALL use the selected server-held revision for import and SHALL block missing revision evidence.
The pipeline SHALL reject a refreshed provider detail whose revision differs from the selected revision before downloading or building a bundle.

#### Scenario: Provider head changes
- **WHEN** the provider revision changes after inspection and before import
- **THEN** the pipeline fails visibly and instructs the operator to refresh and select again without importing mixed-snapshot metadata

#### Scenario: Forged revision
- **WHEN** an import event supplies a client revision
- **THEN** the coordinator receives the selected server-held revision instead

### Requirement: Truthful catalog completion

Import completion SHALL identify the exact catalog record and its stored artifact digest according to SPEC.md section 6.5.
Completion SHALL NOT imply Tenant authorization, Node residency, or successful inference.

#### Scenario: Successful import
- **WHEN** import completes
- **THEN** the operator can open Catalog to inspect the exact version and stored digest with runtime readiness kept separate

### Requirement: Distinct catalog import step

Discovery SHALL distinguish selecting a model for inspection from entering the Catalog import step.
Import SHALL replace discovery content with a Catalog step that carries the selected exact identity and retains progress, error recovery, and completion feedback.
Only the Catalog step SHALL expose the action that starts a new import.

#### Scenario: Enter Catalog and return
- **WHEN** an operator chooses Import for a returned model and then Back to Discover
- **THEN** the Catalog step first presents that model and selected revision, and Back restores the existing query, capability filter, and selection without starting a download

#### Scenario: Return during import
- **WHEN** an operator returns to Discover while a Catalog import is active
- **THEN** the existing coordinator job continues and its progress remains visible without being attributed to a newly selected model

### Requirement: Managed pre-import transfers

The Console SHALL keep the latest download attempt for every repository and revision accessible across model selection and navigation within the running Controller session.
Pause SHALL stop the active HTTP transfer while retaining its partial bytes, completed files, selected revision, and validated metadata.
Resume SHALL continue the same transfer using existing ETag-validated Range handling without resolving a newer provider revision.
Cancel SHALL cooperatively halt the transfer and remove its temporary files before acknowledging completion.
The Controller SHALL serialize lifecycle control against the transition to bundle preparation and reject pause or cancel once finalization begins.
Download job history and paused work are Controller-session state, not restart-persistent state.

#### Scenario: Pause and resume an exact revision
- **WHEN** an operator pauses a transfer and later resumes it
- **THEN** the UI acknowledges pause only after the HTTP transfer ends and resumes the original revision without redownloading completed files

#### Scenario: Cancel before finalization
- **WHEN** cancellation wins the pre-import phase boundary
- **THEN** temporary transfer files are removed and no Catalog record is created

#### Scenario: Finalization has begun
- **WHEN** an operator requests pause or cancel after bundle preparation begins
- **THEN** the server rejects the control and the UI identifies finalization as non-interruptible

#### Scenario: Reopen Catalog from Downloads
- **WHEN** an operator opens a held download from Downloads after navigating away from Catalog
- **THEN** the Console opens that job's Catalog step, minimizes Downloads, and preserves its repository and original revision independently of current search results
- **AND** provider details for a different revision are not presented as the job's original revision or used to start a replacement import silently

#### Scenario: Restart a cancelled download
- **WHEN** an operator reopens a cancelled download and chooses Restart download
- **THEN** a new transfer starts from the beginning for the recorded repository and revision, subject to the existing revision validation, without implying retained partial bytes can resume

#### Scenario: Remove terminal download history
- **WHEN** an operator removes a cancelled, failed, or completed entry from Downloads
- **THEN** the Controller removes that repository/revision's terminal download history across Console views without deleting Catalog records or model files
- **AND** active or paused transfers cannot be removed through this action, and older attempts do not reappear after removal

### Requirement: Direct Catalog destination

The Models entry SHALL open Catalog directly and expose Discover as its peer destination.
Catalog SHALL distinguish persisted imported models from Controller-session import activity without manufacturing persisted records for unfinished jobs.
Download activity SHALL include running, paused, failed, cancelled, and completed attempts while their server-held history exists.

#### Scenario: Return to an unfinished import
- **WHEN** an operator opens Models after leaving a paused import
- **THEN** Catalog lists the paused activity and offers its exact-revision detail without requiring the operator to open Downloads first

#### Scenario: Open a Catalog activity detail
- **WHEN** an operator opens an activity link for a repository and revision
- **THEN** the server validates the lookup against its held jobs and the detail provides Back to Catalog
- **AND** an unknown or expired job provides visible recovery without starting a provider search or a download
