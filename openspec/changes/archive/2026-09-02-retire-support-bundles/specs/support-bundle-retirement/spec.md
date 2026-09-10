## ADDED Requirements

### Requirement: Support Bundle Product Surface Is Retired

Orchard SHALL NOT expose a support-bundle command, Operator API route, Console workflow, tray workflow, manager, archive format, scoped-artifact contract, or redaction-manifest contract.
This pre-release removal SHALL include the implemented local CLI archive pipeline and the unimplemented `orchard.support_bundle.v2` promises.
Orchard SHALL NOT retain a compatibility shim or deprecated tombstone command.
This requirement removes the support-bundle behavior previously described by `SPEC.md` §1.2, §7.3, §7.5, §9.1, §10.2, §10.9, §11.1, §11.8, §11.9, §12.6, §12.7, §13.4, and Milestones 5 and 6.

#### Scenario: Operator invokes the former direct namespace

- **WHEN** an operator invokes `orchardctl support`, `orchardctl support --help`, or a deeper former support-bundle command
- **THEN** Orchard rejects the invocation through the standard unknown-command path
- **AND** the process exits with status 1
- **AND** Orchard does not display former support-bundle help

#### Scenario: Generic help remains available

- **WHEN** an operator invokes a generic root-help form followed by `support`
- **THEN** Orchard renders the normal root help successfully
- **AND** the root command list does not advertise a support namespace

#### Scenario: Removed command has no output side effect

- **WHEN** an operator invokes the former bundle-create command with an output path
- **THEN** Orchard rejects the invocation
- **AND** Orchard creates no archive, staging directory, manifest, or output path
- **AND** Orchard records no support-bundle audit event

### Requirement: Unrelated Diagnostics And Operational Codes Remain

Support-bundle retirement SHALL NOT remove general node, request, scheduler, Runtime Endpoint, dispatch-capacity, or control-plane diagnostics.
Support-bundle retirement SHALL NOT remove scheduler rejection or skip codes, action preview blockers, warnings, consequence codes, confirmation requirements, dispatch-capacity codes, or Sentry filtering.
The support-bundle-only `support_scope` vocabulary SHALL be removed because no independent operational consumer uses it.

#### Scenario: Operator inspects retained diagnostics

- **WHEN** an operator uses a retained diagnostic or scheduler-explanation surface after support-bundle retirement
- **THEN** Orchard returns the same domain result and operational reason codes as before the removal
- **AND** no support-bundle artifact is required to expose that result

### Requirement: Historical Data And Existing Artifacts Are Preserved

Support-bundle retirement SHALL NOT rewrite or delete historical audit rows whose action is `support_bundle.generated`.
Support-bundle retirement SHALL NOT automatically delete an existing support archive or operator-owned file.
No database migration SHALL be required solely to remove the live feature.

#### Scenario: Historical audit row remains readable

- **WHEN** an existing audit row contains the text action `support_bundle.generated`
- **THEN** generic audit readers can still read and retain the row
- **AND** Orchard does not require the removed metrics action-domain mapper to interpret the stored action

#### Scenario: Existing archive remains on disk

- **WHEN** an operator already has a support archive before upgrading to the retirement release
- **THEN** install, update, and default uninstall do not delete that archive merely because the product feature was removed
- **AND** any later cleanup remains an explicit operator action

### Requirement: Lifecycle Namespace Ownership Is Preserved

The Application Support `support/` namespace SHALL remain available for app-owned lifecycle entries and operator-owned contents.
Install and update SHALL preserve operator-owned contents under `config/`, `data/`, `models/`, `bundles/`, `logs/`, and the retained `support/` namespace.
Default uninstall SHALL remove app-owned payloads and support entries while retaining non-app-owned contents according to the existing lifecycle ownership contract.
Support-bundle retirement SHALL NOT change `support/openssl`, install-role, transaction, state-store, signing, or packaging behavior.

#### Scenario: Upgrade preserves retained lifecycle state

- **WHEN** Orchard is upgraded after support-bundle retirement
- **THEN** the app preserves operator-owned contents and required app-owned lifecycle state under the retained namespaces
- **AND** no directory is reclassified solely because support bundles were removed
