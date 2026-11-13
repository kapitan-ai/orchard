# ADR: Withdraw the Amore selection from the DMG distribution contract

## Status

Proposed. Acceptance requires Najib's approval of the exact wording, including
the amended release-governance decision 1.4 and the retained GitHub release-record
role. Authorization to prepare this amendment is not acceptance of this decision.

## Context

The archived DMG service-lifecycle change selected Amore for the outer DMG and
publication integration, and `SPEC.md` §11.3 made that commercial product a
normative dependency. Decision 1.4 of `product-versioning-release-governance`
then approved channel contracts, DMG artifact treatment, and conjunctive
completion across GitHub and Amore.

Native distribution is paused under §11.0 and Orchard ships no packaged builds.
The retained design needs service-independent trust and completion requirements,
not a mandatory commercial customer-delivery provider. Removing a provider does
not remove the second surface: partial-publication states, ordered completion,
credential separation, and publication custody depend on both roles.

## Proposed decision

Withdraw only the Amore vendor selection from decision 1.4. Retain its approved
channel contracts, DMG artifact treatment, and conjunctive completion across the
release record and one customer delivery surface. Keep task 1.4 checked as the
approval history, with this proposed amendment recorded in place.

GitHub remains the named release record under `AGENTS.md` "Tracking and
publication". The §11.3 neutrality rule governs outer DMG tooling and the customer
delivery surface, not that release-record role. This proposal does not abstract
GitHub or authorize a new publication target. A future proposal may replace the
GitHub release-record implementation with a neutral release-registry role while
retaining the same state transitions, conjunctive reducer, audience obligations,
ordering, and separate authorization boundaries.

Under this amendment, no customer delivery surface is selected. Selection
requires an accepted OpenSpec change and live proof of audience restriction,
idempotency, digest inspection, exact-byte promotion, and credential isolation
before trial delivery or pilot or release publication is enabled. An unselected
surface is neither optional nor satisfied. Distribution approval binds the
selected GitHub release-record and delivery-surface target identifiers; changing
either target revokes that approval.

Developer ID signing, Apple notarization, and stapling remain mandatory platform
trust requirements. The exemption is limited to those three requirements: it
does not cover Apple hosting or publication or intermediary services.
Notarization-submission tooling remains inside the neutrality rule. Orchard
retains inner-first signing, capability detection and fail-closed handoff, and
mounted-DMG verification against the verified input app.

## Consequences

Trial delivery and pilot and release publication remain disabled until the
delivery surface is selected and proved, independently of the §11.0 pause.
This decision does not resume distribution, approve a release, or authorize
credential use, signing, notarization, hosting, or publication.

The dormant `scripts/build-dmg.sh` still drives the Amore CLI, which §11.3 permits
but does not require. Confirm or replace that tooling and reconcile its tests and
runbook before distribution resumes. Retain its environment variables, sidecar
names, and fixtures while that integration remains. Archived changes stay as
history, not current vendor mandates.

## SPEC.md impact

Update §11.3 to remove the required commercial customer-delivery integration,
scope neutrality separately from the retained release record, bound the Apple
platform exemption, and preserve capability detection and mounted verification.
Preserve §11.0 and all other signing, notarization, stapling, artifact, and
release-approval gates.
