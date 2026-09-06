## ADDED Requirements

### Requirement: Console Guides Node Enrollment Through Existing Trust Boundaries
Orchard Console SHALL expose **Add Node** from the Nodes workspace and guide an authorized administrator through one Controller-side Node Enrollment journey.
The journey SHALL identify the target Mac and Controller Console action locations separately.
The journey SHALL present installation preparation before short-lived Enrollment issuance as the recommended order.
The journey SHALL show the exact `orchardctl node join --enrollment-bundle PATH` command as a target-Mac action.
The journey SHALL NOT treat installation, download, transfer, service start, or endpoint observation as registration, trust, admission, activation, or scheduling eligibility.
The journey SHALL preserve explicit Node Admission and automatic activation from fresh healthy authenticated evidence.
This refines `SPEC.md` §§4.2 through 4.6, 7.4, 7.5.4, and 10.6.

#### Scenario: Administrator discovers Add Node
- **WHEN** an authorized administrator opens the Console Nodes workspace
- **THEN** the workspace offers **Add Node** as the primary creation action
- **THEN** existing Node inventory and untrusted Runtime Endpoint evidence remain separate

#### Scenario: Guided preparation names the action location
- **WHEN** the administrator opens **Add Node**
- **THEN** Console identifies installation preparation as a target-Mac action
- **THEN** Console identifies Enrollment creation as a Controller Console action
- **THEN** Console recommends preparing the target Mac before creating the short-lived bundle

#### Scenario: Issued bundle has one target command
- **WHEN** Console delivers a Node Enrollment Bundle successfully
- **THEN** Console shows `orchardctl node join --enrollment-bundle PATH`
- **THEN** Console says to run the command on the target Mac with the downloaded bundle path
- **THEN** Console does not report the Node as registered until certificate-backed redemption completes

### Requirement: Console Browser Delivery Is One-Time And Fail-Closed
Orchard Console SHALL support one-time Node Enrollment Bundle delivery through an authenticated same-origin browser session when browser delivery is selected.
Console browser delivery SHALL use the same versioned artifact contract as CLI publication.
The Enrollment SHALL remain `pending_publication` until the client reports that the download attempt started successfully.
The Bootstrap Token and encoded bundle bytes MUST NOT enter a URL, flash message, session, cookie, log, audit payload, `data-*` attribute, or reusable download endpoint.
The client SHALL clear transient bundle bytes and revoke any object URL after starting or failing the download.
On reported client failure, Orchard SHALL mark the Enrollment `output_failed` and SHALL NOT allow redemption.
On disconnect or lost acknowledgement, Orchard SHALL leave the Enrollment non-redeemable until stale-publication reconciliation marks it `output_failed`.
Console SHALL NOT redisplay, resend, restore, or automatically renew the same bundle.
Browser delivery SHALL NOT claim to prove destination-file custody or protected transfer to the target Mac.
This refines `SPEC.md` §§7.5.4, 8.1, and 10.2.

#### Scenario: Browser accepts one-time delivery
- **WHEN** the authenticated client starts a download for the newly created bundle
- **THEN** the client acknowledges only the Enrollment identifier
- **THEN** Orchard verifies that identifier against socket-owned pending issuance state
- **THEN** Orchard marks the Enrollment `issued`
- **THEN** Console removes the one-time bundle bytes from reachable application state

#### Scenario: Browser delivery fails
- **WHEN** the client cannot create or start the bundle download
- **THEN** the client reports failure with only the Enrollment identifier
- **THEN** Orchard marks the Enrollment `output_failed`
- **THEN** Console explains that no Node identity or trust was established
- **THEN** Console offers **Create new enrollment** without redisplaying the failed bundle

#### Scenario: Delivery acknowledgement is lost
- **WHEN** the client disconnects after Enrollment creation without a valid success or failure acknowledgement
- **THEN** the Enrollment remains `pending_publication` and cannot be redeemed
- **THEN** stale-publication reconciliation may mark it `output_failed`
- **THEN** reconnecting does not redisplay or resend the same bundle
- **THEN** a URL containing only the non-secret Enrollment identifier restores durable status
- **THEN** a still-`pending_publication` Enrollment does not expose a join command

#### Scenario: Delivery acknowledgements race
- **WHEN** a stale client success or failure acknowledgement arrives after Console has left delivery state
- **THEN** Console ignores it
- **WHEN** a publication transition returns an ambiguous error
- **THEN** Console reconciles the claim against the durable Enrollment state
- **THEN** Console does not claim output failure for an Enrollment already stored as `issued` or `consumed`
- **THEN** Console does not claim completed output failure while the Enrollment remains `pending_publication`

#### Scenario: Duplicate issuance event arrives
- **WHEN** an issuance event arrives after Console has left the enrollment-form stage
- **THEN** Console ignores the event
- **THEN** Console does not create another provisioned Node or replace the in-flight Enrollment

#### Scenario: Durable recovery respects publication surface
- **WHEN** a status URL names an Enrollment created by a non-Console publication surface
- **THEN** Console does not claim that a browser accepted its download
- **THEN** Console does not reconstruct a browser download path or command
- **THEN** Console directs the operator to continue from the issuing surface or create a new Console Enrollment

#### Scenario: Administrator returns to the base Add Node route
- **WHEN** browser navigation returns from an Enrollment status URL to `/console/nodes/new`
- **THEN** Console clears the previous delivery and monitor state
- **THEN** Console shows a fresh enrollment form without issuing another bundle

### Requirement: Console Observes Registration Automatically
After successful bundle delivery, Console SHALL poll durable Enrollment and Node state automatically at a bounded interval.
Console SHALL show the last successful check time and MAY offer **Refresh now** as a fallback.
Console SHALL NOT ask the operator to record package installation, service start, registration, transport authorization, health, or activation.
Before registration, Console SHALL present one current blocker with the exact target-Mac action and expected result.
After registration, Console SHALL link to the existing explicit admission review.
After admission, Node activation SHALL remain system-managed and SHALL require fresh healthy authenticated evidence.

#### Scenario: Registration remains pending
- **WHEN** the Enrollment is issued and its Node remains `provisioned`
- **THEN** Console says to run the generated join command on the target Mac
- **THEN** Console continues automatic checks without requiring an operator status action
- **THEN** scheduling remains blocked

#### Scenario: Registration completes
- **WHEN** certificate-backed redemption advances the Node to `registered`
- **THEN** the next automatic check shows **Registered - awaiting admission**
- **THEN** Console offers a link to admission review
- **THEN** Console does not admit or activate the Node automatically

#### Scenario: Enrollment can no longer register
- **WHEN** the Enrollment is expired, revoked, or `output_failed`
- **THEN** Console names the terminal state and why the bundle cannot be used
- **THEN** Console states that trust and Node identity were not established by that bundle
- **THEN** Console offers **Create new enrollment** and does not offer restore or redisplay

#### Scenario: Consumed enrollment passes its original expiry
- **WHEN** an Enrollment is `consumed` and its original token expiry passes
- **THEN** Console continues to show durable registration, admission, and activation state
- **THEN** Console does not show bundle-transfer instructions or a join command
- **THEN** Console does not treat the completed one-time redemption as an expired recovery flow

### Requirement: Initial Pool Is Non-Authoritative Admission Intent
The Console Add Node form SHALL present `general` as the default initial Pool intent and SHALL explain that a Pool is an existing scheduling group.
The Pool intent MAY be changed before issuance and during admission review.
Pool intent SHALL NOT establish identity, trust, registration, admission, activation, or request-time scheduling eligibility.
Custom Pool management SHALL remain outside the Add Node journey.

#### Scenario: Administrator accepts the general Pool intent
- **WHEN** the administrator creates an Enrollment without changing Pool intent
- **THEN** Console records `general` as bounded non-secret intent
- **THEN** admission review may prefill `general`
- **THEN** admission execution still revalidates every trust, policy, capacity, leadership, and write-path blocker

#### Scenario: Active Node is evaluated per request
- **WHEN** the admitted Node later becomes `active`
- **THEN** Console may say Orchard can consider the Node for scheduling
- **THEN** Console does not claim that every exact Model is compatible, loaded, eligible, or guaranteed dispatch
