## ADDED Requirements

### Requirement: Workspace display preserves the Tenant boundary

The Console and Developer Portal SHALL use Workspace as the product-facing label for exactly one existing Tenant governance boundary, reconciling SPEC.md sections 2.3 and 7.4a and the glossary before implementation.
The change SHALL preserve Tenant UUIDs, slugs, persisted relationships, API/CLI vocabulary, audit identifiers, and existing Portal URLs.
Team SHALL remain non-authorizing API Client metadata as required by the existing service-account provisioning decision.

#### Scenario: Existing scope is opened after the display change
- **WHEN** an operator opens an existing Organization through an old Console URL
- **THEN** the same Tenant record appears as a Workspace with unchanged grants, users, and credentials
- **AND** existing integration commands and Portal links remain valid

#### Scenario: Team grouping is inspected
- **WHEN** an operator groups API Clients by Team
- **THEN** the UI describes grouping metadata and exposes no Team membership or permission controls

### Requirement: Access provides scoped section navigation

Access SHALL provide a plural Workspace list and separate Workspace creation.
Workspace detail SHALL provide Overview, Model access, Portal users, and API credentials through whitelisted, reloadable section navigation.
Inactive sections SHALL not remain accessible through keyboard navigation or the accessibility tree.
Models and Nodes SHALL retain their cluster-level ownership and navigation.

#### Scenario: Returning operator manages credentials
- **WHEN** an operator chooses a Workspace and opens API credentials
- **THEN** the page displays that Workspace identity, reload preserves the section, and Back returns to the Workspace list

#### Scenario: Legacy deep link targets a section
- **WHEN** an old Tenant detail URL or recognized section anchor is opened
- **THEN** the corresponding Workspace and intended section remain reachable under the existing authentication boundary

### Requirement: Model access is grounded in persisted grants

The Model access section SHALL read exact catalog identities and distinguish enabled, disabled, not-granted, and unavailable evidence under SPEC.md sections 6.6 and 10.9.
Revoked grants SHALL appear as absent unless separately evidenced; current grant reads SHALL not distinguish them from never-granted records.
The initial increment SHALL provide a scoped supported operator handoff for changes rather than creating a new unchecked mutation path.
A prepared handoff SHALL not imply that the grant changed or that runtime inference is ready.

#### Scenario: Model grant is missing
- **WHEN** the selected Workspace has no enabled grant for a selected exact Model
- **THEN** the page shows the actual grant state and can prepare a scoped administrator handoff without granting access

#### Scenario: Grant read fails
- **WHEN** the persisted access read fails
- **THEN** the page shows unavailable evidence and retry instead of reporting no access or successful authorization

### Requirement: Colleague handoff retains one Workspace

The guided handoff SHALL retain the server-resolved Workspace and exact selected catalog Model through access inspection, invitation preparation, scope review, and manual delivery.
It SHALL preserve the separation of grants, Portal membership, and inference credentials in SPEC.md section 7.4a.
Switching Workspace SHALL clear previous scoped drafts and secret-bearing state.
Successful refresh SHALL reconcile the current step and unlocked navigation with the selected Model and Portal User that still exist.
Missing selected Models SHALL return the operator to Model access; missing or disabled Portal Users SHALL return the operator to Portal invitation.

#### Scenario: Scope is reviewed before invitation
- **WHEN** the operator reviews an invitation
- **THEN** the page shows the recipient, one Workspace, selected Model access state, and that cluster administration and API credentials are not included

#### Scenario: Request to another Workspace is forged
- **WHEN** a child-resource event supplies an identifier belonging to another Workspace
- **THEN** the server rejects it without reading or mutating the other Workspace's resource

#### Scenario: Selected Model disappears during handoff
- **WHEN** refresh no longer finds the exact selected Model while the operator is in a later step
- **THEN** the handoff returns to Model access and later steps remain unavailable until their prerequisites are restored

#### Scenario: Portal User becomes disabled during handoff
- **WHEN** refresh finds the selected Portal User disabled or missing
- **THEN** the handoff returns to Portal invitation and cannot issue an invite from a later step

### Requirement: Invitation outcomes reflect actual service state

Portal User creation, invite-token issuance or reissue, activation, expiry, disablement, and secret display SHALL preserve the existing Developer Portal contract.
Creating the invited Portal User SHALL not be presented as issuing or delivering an invite link.
Copy invite SHALL issue or reissue a fresh single-use token and invalidate the previous token.
The Console SHALL distinguish preparation from successful creation and manual delivery.
Failure SHALL retain safe non-secret inputs and offer retry without fabricating invitation success or sending email.
Leaving the invite reveal step SHALL discard its plaintext URL and cancel its display-expiry timer.
Invite issuance SHALL be available only in that step with a selected Model and an invited Portal User.

#### Scenario: Invitation service fails
- **WHEN** invitation creation fails after review
- **THEN** the recipient and Workspace remain available for recovery and no pending invitation is falsely displayed

#### Scenario: Portal User is created
- **WHEN** the service confirms creation of the invited Portal User
- **THEN** the Console shows that persisted user state and that no invite link has yet been issued or delivered

#### Scenario: Invite link is issued
- **WHEN** Copy invite successfully issues or reissues an invite token
- **THEN** the Console offers the single-use link through the existing one-time display and explains manual delivery
- **AND** it does not assert that the colleague received or accepted it

#### Scenario: Link issuance fails after user creation
- **WHEN** the Portal User exists but Copy invite fails
- **THEN** recovery preserves the user and retries link issuance without recreating the user or fabricating a link

#### Scenario: Return to invite delivery after leaving it
- **WHEN** the operator leaves the invite reveal step and later returns
- **THEN** the previous plaintext URL remains unavailable and another explicit issuance is required to show a new link

### Requirement: Credential and first-request handoff is truthful

Portal authentication SHALL not stand in for inference credentials or Console/operator authority.
The personal developer path SHALL use the Portal User's own tenant-direct API Key under SPEC.md section 7.4a; API Client provisioning SHALL remain separate.
Console examples SHALL contain a literal placeholder and never retain an actual inference key.
Only the real Portal mint response SHALL show the signed-in Portal User's newly minted secret or curl under its existing one-time-display contract.
A request guide SHALL not expose another principal's credential or display simulated acceptance, dispatch, or completion.
The Console Playground's seeded legacy Tenant SHALL not be represented as the chosen Workspace's request context.

#### Scenario: Colleague has accepted but has no key
- **WHEN** a colleague has Portal access without an inference credential
- **THEN** the guide explains the actual Portal self-service key path and preserves separate model grant and runtime readiness checks

#### Scenario: First request has not run
- **WHEN** only an invitation or request example has been prepared
- **THEN** the journey identifies the remaining external action and does not mark First request completed

#### Scenario: Requested handoff Model is unavailable
- **WHEN** the handoff names an exact Model that is no longer active or authorized for the colleague's Workspace
- **THEN** request guidance reports that state and does not silently substitute another Model
- **AND** examples without a requested Model choose deterministically from the authorized active set

### Requirement: Default Workspace removes scope-creation friction

Orchard SHALL use the existing seeded Tenant as the default Workspace on fresh installations, preserving its stable identity and existing relationships.
The untouched built-in display name SHALL appear as Default workspace; customized names SHALL be preserved with a Default indicator.
Default designation SHALL be based on stable identity rather than display-name or slug matching.
The default Workspace SHALL not receive implicit model grants, credentials, Portal membership, or runtime readiness.

#### Scenario: First onboarding task
- **WHEN** a new installation has only its seeded default Workspace
- **THEN** the operator can start a colleague handoff in that Workspace without creating or choosing a scope first
- **AND** the selected Workspace remains visibly identified throughout the handoff

#### Scenario: Existing installation is upgraded
- **WHEN** the existing seeded Tenant already has keys, grants, users, or a customized name
- **THEN** the same record becomes the default Workspace presentation without creating another Tenant, resetting its name, or changing its relationships

#### Scenario: Another Workspace is selected
- **WHEN** the operator opens an explicit Workspace route or selects a Workspace from multiple choices
- **THEN** default-onboarding behavior does not replace that selected scope or its draft

#### Scenario: Seeded Workspace is unavailable
- **WHEN** the seeded Workspace record is missing or cannot be read
- **THEN** onboarding shows a recoverable setup/read error without creating records during page reads or silently falling back to another Workspace

### Requirement: Guided steps preserve visible orientation

The guided flow SHALL display Workspace, Model access, Portal invitation, Review scope, Colleague handoff, and First request as six ordered steps with a current step number.
Each step SHALL replace the prior visible content rather than append a scroll destination.
Unavailable future steps SHALL remain visible, dimmed, and non-interactive.
Workspace management sections SHALL not be presented as completion of the guided handoff.

#### Scenario: Default Workspace starts the journey
- **WHEN** the only default Workspace is selected automatically for onboarding
- **THEN** step 1 remains visibly resolved and the operator enters Model access as step 2 of 6 with the Workspace name visible
- **AND** no grant, invitation, or request completion is inferred

#### Scenario: Return after invitation activation
- **WHEN** the colleague already has an activated Portal User but Model access is missing
- **THEN** recovery returns to the scoped Model access handoff without creating another invitation or resetting completed Portal activation

#### Scenario: Narrow viewport navigation
- **WHEN** the guided journey is used at a narrow viewport
- **THEN** the current step, Workspace, primary action, and return/retry controls remain reachable without horizontal page overflow or scrolling to an appended step
