## MODIFIED Requirements

### Requirement: Console Guides Node Enrollment Through Existing Trust Boundaries

Orchard Console SHALL expose **Add Node** from the Nodes workspace and guide an authorized administrator through one Controller-side Node Enrollment journey.
The journey SHALL identify acquisition, target-host installation, Controller Console enrollment creation, secure transfer, target-host join, registration, admission, authorization, readiness, and serving as distinct states.
For the existing all-in-one and source-development profiles, the journey SHALL continue to show `orchardctl node join --enrollment-bundle PATH`.
For the accepted dedicated macOS Node distribution profile only, the journey SHALL require selection of a compatible verified Node release and SHALL show the expected post-install `orchard-node node join --enrollment-bundle PATH` command or signed-app Join action as the target-Mac surface.
The dedicated surface SHALL NOT be shown when the profile is not selected or the release is unavailable, incompatible, withdrawn, expired, or unverifiable.
Dedicated-profile enrollment issuance and actionable join guidance SHALL remain disabled until the target-host join implementation reports its local installation and pre-redemption checks available.
Console SHALL NOT claim to observe target-host installation before enrollment.
The target-host join SHALL verify the installed app and payload locally before token redemption.
The enrollment bundle schema, one-time browser delivery, no-redisplay behavior, short expiry, Pool intent, and explicit Node Admission SHALL remain unchanged.
Automatic activation from fresh healthy authenticated evidence SHALL remain.
The dedicated profile SHALL publish authenticated health and Worker Runtime facts after exact Peer Grant activation and authenticated OTP TLS Distribution, independently of request-time dispatch authorization.
The Controller-owned activation evaluator SHALL promote `admitted -> active` only after it verifies those fresh facts, current admission, exact identity, active grant, successful activation-boundary evidence, and the phase-appropriate capacity policy persisted by admission.
Scheduler eligibility and request-time leader and dispatch-capacity authorization SHALL follow activation.
The journey SHALL NOT treat download, installation, transfer, local identity creation, service start, endpoint observation, registration, admission, Peer Grant delivery, Runtime Endpoint readiness, or scheduling eligibility as equivalent to or proof of any later state.
Until issue #371 has an accepted contract and implementation, lost or terminal pre-registration enrollment recovery SHALL retain the existing distinct-name behavior and SHALL NOT promise same-name replacement.
Lost post-consumption responses SHALL remain on the existing matching-enrollment, matching-key, and matching-CSR resume path.
This refines `SPEC.md` §§4.2 through 4.6, 7.4, 7.5.4, 10.6, 11, and 11.9 without changing enrollment authority.

#### Scenario: Existing profile receives the existing command

- **WHEN** an administrator creates an enrollment for an existing all-in-one or source-development profile
- **THEN** Console shows `orchardctl node join --enrollment-bundle PATH`
- **AND** no dedicated app or release is required by that guidance

#### Scenario: Dedicated profile receives its target-host join guidance

- **WHEN** the administrator selects a compatible, currently authorized dedicated Node release
- **THEN** Console shows the expected post-install `orchard-node node join --enrollment-bundle PATH` command or signed-app Join action on the target Mac
- **AND** it does not require `orchardctl` or a local Controller on that host

#### Scenario: Dedicated release is not eligible

- **WHEN** the dedicated release is incompatible, withdrawn, expired, or unverifiable
- **THEN** Console blocks enrollment creation for that profile with acquisition or verification guidance
- **AND** it does not spend or deliver a bootstrap token

#### Scenario: Dedicated join implementation is unavailable

- **WHEN** the Controller has eligible release metadata but the target-host join capability is not implemented or enabled
- **THEN** Console keeps dedicated-profile enrollment issuance and actionable join guidance disabled
- **AND** existing profile enrollment remains available

#### Scenario: Target app is absent after enrollment delivery

- **WHEN** the dedicated join surface runs on a host without the exact verified installed app and payload
- **THEN** local preflight rejects join before token redemption
- **AND** Console does not represent installation as remotely observed fact

#### Scenario: One-time bundle is lost before registration

- **WHEN** the bundle is lost, inaccessible, expired, revoked, or publication-failed before registration
- **THEN** Console does not redisplay or replay the secret
- **AND** it does not promise same-name replacement unless issue #371 has separately landed
