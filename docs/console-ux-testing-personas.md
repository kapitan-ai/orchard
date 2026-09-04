# Console UX Behavioral Personas and Scenario Testing

This guide provides reusable behavioral personas and scenario scripts for Orchard Console research, prototype evaluation, pre-release usability testing, and browser-level regression planning.
The personas are research hypotheses and testing lenses, not product roles, permission grants, or claims about actual users.
`SPEC.md`, accepted decisions, accepted OpenSpec changes, and implemented authorization remain the product authorities.
When this guide conflicts with those authorities, the authoritative contract wins and this guide must be corrected.

The guide is intentionally behavioral and authority-based.
It avoids demographic biographies and decorative personality traits that do not change a participant's task, authority, evidence, or constraints.
External design references and transient research notes may inform a study, but they do not establish Orchard behavior.

## How to use the framework

Select the persona whose job, authority, starting knowledge, and available evidence match the behavior being tested.
Give the participant only the starting state and task prompt before they begin.
Do not teach Orchard vocabulary in the prompt when the study is intended to test whether the interface communicates that vocabulary.
Record the first action, wrong turns, requests for help, attempted unauthorized actions, and statements that incorrectly collapse two system states.
Ask the participant to name the evidence they would require before declaring success.
Treat completion without the required evidence as a critical misunderstanding rather than a successful task.
Treat answers about unresolved contracts as research observations rather than pass or fail criteria.

The same person may exercise more than one persona in a small deployment, but each test should make the active authority boundary explicit.
A persona name never expands the participant's credentials.
An action is allowed only through the surface-appropriate authenticated authorization, such as an RBAC Access Level, an active Organization-scoped Portal User session for that user's portal actions, or local machine authority for host-local work.

## Evidence ladder

The following distinctions should remain visible across every relevant scenario.

1. Installation proves that Orchard components exist on a machine, but it does not prove Node identity or cluster trust.
2. Enrollment and certificate-backed registration prove Node identity, but they do not grant Node Admission.
3. Node Admission is an explicit administrator decision, while `admitted` to `active` follows automatically after fresh healthy authenticated evidence.
4. An active Node is not necessarily eligible for a particular exact Model, policy, request, or workload.
5. Model Catalog state is separate from Organization access and per-Node Model Placement state.
6. Downloaded, verified, cached, loaded, eligible, authorized, selected, and successfully invoked are separate facts.
7. Desired placement or residency policy is not proof that the desired state has been reached.
8. A successful inference request is the final product-level proof that authorization, scheduling, runtime readiness, and execution aligned for that request.

## Behavioral personas

### Department Operator

- **Job to be done:** The Department Operator makes an Organization usable for approved applications while understanding when cluster work must be handed to a platform administrator.
- **Actual Orchard authority and prohibited actions:** The participant exercises only the effective Organization-scoped rights assigned to their principal, such as `tenant_admin`, and must not assume authority to admit or decommission Nodes, mutate the global Model Catalog, inspect another Organization, or perform cluster-wide operations.
- **Technical confidence and starting mental model:** The participant understands API access and service ownership, but may initially expect Orchard to behave like a hosted workspace where choosing a Model makes it immediately available.
- **Information and system access available:** The participant can see their Organization's approved access, API Clients, API Tokens, quota, routing, and model availability surfaces that their credentials permit, plus handoff status supplied by the cluster operator.
- **Likely misconceptions:** The participant may treat Organization, Tenant, Team, API Client, Portal User, API Token, and Access Level as interchangeable, or may assume Catalog activation grants access automatically.
- **Evidence required before declaring success:** The participant must identify the exact Model, effective Organization access, usable credential, eligible serving path, and successful inference result without relying on a green Catalog or Node badge alone.
- **Relevant prototype and product scenarios:** This persona leads Organization access, developer enablement, exact-Model request readiness, and the Department Operator side of Add Node and Model-placement handoffs.
- **Accessibility or operational constraints:** Tests should cover keyboard operation, non-color status interpretation, one-time secret custody, and handoffs where the participant cannot access the target machine or cluster-admin controls.

### Node Host Custodian

- **Job to be done:** The Node Host Custodian installs and operates Orchard on a specific machine so that a cluster administrator can establish and review trustworthy Node identity.
- **Actual Orchard authority and prohibited actions:** The participant may exercise local machine-administrator authority to verify media, install the selected Install Role, protect enrollment material, run local join or service operations, and collect safe diagnostics, but local root authority does not grant Console admin, Node Admission, Organization access, or model-access authority.
- **Technical confidence and starting mental model:** The participant understands macOS administration, networking, services, and protected files, but may expect successful installation or network reachability to be equivalent to cluster trust.
- **Information and system access available:** The participant has the target machine, the approved distribution media, the protected Node Enrollment Bundle, the exact local command or guided flow, local service output, and Controller identity and trust-pin information needed for enrollment.
- **Likely misconceptions:** The participant may confuse the Node Agent with a Worker Runtime, a Bootstrap Token with durable identity, a Node Certificate with Node Admission, or a Runtime Endpoint observation with a registered Node.
- **Evidence required before declaring success:** The participant must show verified installation, protected bundle handling, successful certificate-backed registration, a stable Node identity returned to the administrator, and a clean handoff without claiming admission, activation, or workload eligibility.
- **Relevant prototype and product scenarios:** This persona leads installation, enrollment, registration, expired-bundle recovery, service recovery, network diagnosis, and cross-role handoff scenarios.
- **Accessibility or operational constraints:** Tests should include remote shells, restricted clipboard or file-transfer channels, root-authorization prompts, slow or disconnected networks, narrow terminal windows, and commands that remain understandable without relying on color.

### Model Curator or ML Engineer

- **Job to be done:** The Model Curator introduces and qualifies an exact Model artifact while preserving provenance, capability limits, and the distinction between Catalog, files, runtime, and scheduling state.
- **Actual Orchard authority and prohibited actions:** The participant may prepare and inspect Model Bundles, verify trusted evidence, request or perform authorized import and activation, and assemble qualification evidence, but must not infer Organization grants, Node eligibility, runtime installation, support status, or production readiness from import success alone.
- **Technical confidence and starting mental model:** The participant understands checkpoints, quantization, tokenizers, runtimes, and hardware constraints, but may initially think in model-family names instead of Orchard's exact Model identity.
- **Information and system access available:** The participant has the source and exact version, manifest, trusted digest or detached evidence, Catalog metadata, qualification requirements, placement observations, runtime-provider evidence, and failure details allowed by their role.
- **Likely misconceptions:** The participant may confuse a Model Bundle with the imported Artifact Bundle, trust the deprecated manifest digest as Catalog authority, treat `cached` as `loaded`, or treat a plausible response as a support claim.
- **Evidence required before declaring success:** The participant must show exact identity, provenance, successful secure import, authoritative post-import verification, and capability-scoped qualification evidence appropriate to the claim, while naming Organization grants, current Placement state, compatibility, and inference as separate additional gates only when the claim is end-to-end application readiness.
- **Relevant prototype and product scenarios:** This persona leads exact Model discovery, acquisition, verification, placement-policy interpretation, load failure diagnosis, and qualification-boundary scenarios.
- **Accessibility or operational constraints:** Tests should include very large artifacts, air-gapped or bandwidth-limited transfer, long verification and cold-load times, resumable progress, machine-readable failure codes, and comparison views that do not depend on dense color-only tables.

### Application Developer

- **Job to be done:** The Application Developer obtains an approved credential, discovers Models visible to their Organization, and integrates a reliable inference call without needing cluster-administration knowledge.
- **Actual Orchard authority and prohibited actions:** The participant may authenticate Public Inference with a tenant-direct API Key that resolves to the Tenant principal, or with a service-account-owned API Token whose enabled API Client has tenant-scoped `inference_client` access.
  Separately, an Organization-scoped Portal User may mint and revoke only their own portal-minted tenant-direct API Keys, but a Portal session does not authorize Console, Operator API, Admin API, or Public Inference by itself.
- **Technical confidence and starting mental model:** The participant is comfortable with HTTP APIs, SDKs, and environment variables, but may expect a portal login, copied bearer credential, or visible Catalog entry to imply every other permission.
- **Information and system access available:** The participant has their Organization-scoped Developer Portal, show-once API Key or API Token output, callable exact Model identifiers returned by `/v1/models`, example requests, stable public errors, and application logs they control.
- **Likely misconceptions:** The participant may confuse Portal User identity with the Public Inference principal, expect a disabled Portal User to revoke previously minted API Keys, or assume `401`, `403`, and capacity failures mean the same thing.
- **Evidence required before declaring success:** The participant must protect the one-time secret, authenticate with the correct bearer credential, select a Model returned for the effective Organization, receive a successful response, and distinguish credential, authorization, model, and runtime failures.
- **Relevant prototype and product scenarios:** This persona leads Portal invitation, portal-minted API Key creation and revocation, `/v1/models` discovery, first inference, invalid credential, unauthorized Model, and retry-safe client behavior scenarios.
- **Accessibility or operational constraints:** Tests should cover copy errors, screen-reader labeling of show-once secrets, keyboard-only Portal use, reduced motion, expired sessions, and environments where production secrets cannot be pasted into a browser recording or support artifact.

### On-call Operator or Platform Generalist

- **Job to be done:** The On-call Operator restores safe service by locating the failed authority or runtime boundary, taking only permitted operational actions, and proving recovery with current evidence.
- **Actual Orchard authority and prohibited actions:** The participant may use `operator` authority for runtime operations, diagnostics, request cancel or retry, and permitted Node lifecycle actions, but may not mutate Organizations, keys, or other admin-only state unless separately assigned `admin` authority.
- **Technical confidence and starting mental model:** The participant understands distributed systems and incident response, but may be unfamiliar with the exact cluster, recent policy changes, or whether an observation is durable authority or diagnostic evidence.
- **Information and system access available:** The participant has Console status, bounded diagnostics, lifecycle and health, freshness, Runtime Endpoint observations, scheduler explanations, request attempts, stable reason codes, audit references, and approved CLI or API operations.
- **Likely misconceptions:** The participant may equate healthy with schedulable, active with exact-Model readiness, loaded with authorized, retryable with safe to retry after output, or Cancel Drain with a return to active service.
- **Evidence required before declaring success:** The participant must identify the failed boundary, show that the chosen action was authorized and audited, confirm current health and eligibility, and obtain a fresh inference result from an Application Developer or separately authorized Public Inference principal without hiding unresolved execution or partial-failure state.
- **Relevant prototype and product scenarios:** This persona leads reciprocal Model-first and Node-first diagnosis, degraded clusters, one-request retry, load failures, cordon and drain, recovery, and destructive-action preview scenarios.
- **Accessibility or operational constraints:** Tests should include time pressure, dark and low-light use, stale tabs, narrow screens, keyboard navigation, reduced motion, long-running actions, and the need to copy stable reason codes without exposing secrets.

### Security and Compliance Reviewer

- **Job to be done:** The Security and Compliance Reviewer determines whether a sensitive workflow preserved identity, authorization, tenant isolation, secret custody, redaction, and audit requirements.
- **Actual Orchard authority and prohibited actions:** Orchard does not currently define a dedicated reviewer Access Level, so this participant should receive read-only exported evidence or supervised access and must not mutate production state merely because they can inspect it.
- **Technical confidence and starting mental model:** The participant understands control evidence and threat boundaries, but may not know which Orchard observations are authoritative, derived, transient, or intentionally omitted.
- **Information and system access available:** The participant has sanitized audit records, decision references, credential prefixes, bounded status and scheduler evidence, retention and capture settings, qualification records, and approved support evidence without plaintext secrets or raw tenant content.
- **Likely misconceptions:** The participant may treat absence from a redacted artifact as proof that an event did not occur, confuse Portal User provenance with Bearer ownership, or assume Node Certificate possession authorizes admission or production BEAM access.
- **Evidence required before declaring success:** The participant must trace actor, scope, target, decision, timestamp, and outcome while confirming that secrets, raw content, cross-Organization identifiers, and unsafe diagnostics were not persisted or disclosed.
- **Relevant prototype and product scenarios:** This persona leads access-denial, cross-Organization isolation, one-time secret, invitation, admission, destructive action, audit, redaction, and evidence-retention scenarios.
- **Accessibility or operational constraints:** Tests should cover read-only workflows, redacted or partially unavailable evidence, keyboard navigation, text alternatives for status, export review outside Console, and an explicit distinction between a verification gap and a verified absence.

## Scenario matrix

The matrix uses scenario cards so every scenario preserves the same fields without forcing long evidence into an unreadable wide table.
Each card may be run against a concept, clickable prototype, instrumented product build, or automated browser test at the maturity appropriate to the claims being tested.

### S1: Add Node from installation to workload eligibility

- **Contract and maturity:** `SPEC.md` sections 4.1 through 4.4 and 10.5 through 10.6 define the identity, lifecycle, trust, and admission boundaries, while `docs/operator-journey.md` identifies the complete packaged cross-machine guided flow as target product intent pending packaged acceptance.
- **Persona:** The Node Host Custodian performs machine-local work, the Department Operator initiates and tracks the need, and a separately authorized administrator performs Node Admission.
- **Starting state:** A healthy Controller exists, no pending enrollment exists, a supported machine has no authorized Orchard role, and an exact Model is already available to an approved Organization on at least one other path.
- **Task prompt:** A new supported machine is ready to contribute inference capacity, so add it safely and show when Orchard may schedule the exact Model on it.
- **Allowed authority:** The Department Operator may request capacity, an administrator may issue the per-Node Enrollment Bundle and later review and admit the registered Node, and the custodian may receive the protected bundle, verify media, install the `node-agent` Install Role, and complete machine-local registration.
- **Success evidence:** The flow shows installation, bundle issuance and expiry, certificate-backed registration, administrator review, explicit admission, automatic healthy activation, exact-Model compatibility and residency, current capacity, and Organization authorization without collapsing any stage.
  The accepted attempt for the successful terminal request identifies the newly added Node and exact Model version and shows that final revalidation and runtime acceptance succeeded.
- **Critical misunderstandings:** Installation is not enrollment, observation is not registration, registration is not admission, admission does not require a manual Activate action, and active is not universal workload readiness.
- **Prototype observations:** Record where each participant changes surfaces or machines, what they transfer, whether they can resume after delay, when they ask for help, and the first point at which they claim the Node is ready.
- **Candidate automated regression checks:** Browser tests should verify ordered stage labels, disabled admission before trusted registration, a side-effect-free Action Preview, non-bypassable blockers, any action-specific confirmation requirements returned by the preview, no manual Activate control, non-color status semantics, and exact-Model readiness that remains separate from Node lifecycle.

### S2: Add Node partial failure, retry, and recovery

- **Contract and maturity:** `SPEC.md` sections 4.1 through 4.5, 10.5 through 10.6, and 12.1 define fail-closed trust and Node recovery invariants, while guided packaged resume and bundle-transfer behavior remain target or unresolved where `docs/operator-journey.md` says acceptance is incomplete.
- **Persona:** The Node Host Custodian leads local recovery while the On-call Operator observes Controller-side state and an administrator retains admission authority.
- **Starting state:** Installation succeeded, but either the Enrollment Bundle became invalid or expired before registration, or the registration response was lost after the one-time token was consumed, and an untrusted Runtime Endpoint observation may also be present.
- **Task prompt:** Recover the interrupted join without trusting stale material, duplicating identity, or admitting observation-only evidence.
- **Allowed authority:** For invalid or expired material, the custodian may inspect safe local status and continue only after an administrator revokes or reissues bootstrap authority.
  For a lost registration response after token consumption, the custodian may resume only with the matching enrollment identifier, locally held Node key, and CSR fingerprint, while only an administrator may admit the registered Node.
- **Success evidence:** Invalid or expired material is rejected and replaced through an administrator-issued path, while a consumed attempt with a lost response resumes idempotently only when the enrollment identifier, local Node key, and CSR fingerprint match.
  Either path produces one stable registered Node identity, keeps stale candidate evidence non-schedulable, and reaches activation only after fresh authenticated health.
- **Critical misunderstandings:** Retrying must not reuse invalid or expired secrets, a lost registration response must not force reissue when the consumed attempt can be matched safely, different key material must fail closed, and a new observation must not create a second trusted Node.
- **Prototype observations:** Record whether the participant can identify the failed boundary, whether recovery guidance names the responsible role and machine, and whether progress survives navigation or session loss.
- **Candidate automated regression checks:** Tests should distinguish invalid or expired material that requires rejection and reissue from a consumed registration attempt that resumes only with the matching enrollment identifier, local Node key, and CSR fingerprint.
  Guided browser checks remain candidates until an implemented public seam fixes the resume behavior; other checks should cover generic secret-safe failures, candidate-versus-Node labeling, identity mismatch, inaccessible Controller recovery, and no scheduling before admission and fresh activation.

### S3: Discover and acquire an exact Model

- **Contract and maturity:** `SPEC.md` sections 6.1 through 6.7 define exact Model identity, import, Catalog, verification, and distribution, while any marketplace-like discovery experience or unimplemented remote distribution path remains a prototype hypothesis rather than current product behavior.
- **Persona:** The Model Curator leads the task and hands Organization access decisions to the Department Operator or an appropriately authorized administrator.
- **Starting state:** A model family is known, but the exact checkpoint or version is not yet in the Model Catalog and no Node-local Artifact Bundle exists.
- **Task prompt:** Find the approved exact Model, import it with trustworthy provenance, and explain what remains before an application can call it.
- **Allowed authority:** The curator may inspect source metadata and perform only the import, verification, and Catalog actions their admin authority permits, while Organization grants, routing, and credentials require their own assigned authority.
- **Success evidence:** The participant selects one exact Model identity, verifies source and final imported Artifact Bundle evidence, reaches the appropriate Catalog state, and names Organization access, distribution, placement, eligibility, and inference as later independent gates.
- **Critical misunderstandings:** The Catalog is not a marketplace guarantee, a family name is not exact identity, source verification is not post-import verification, activation does not grant access, and import does not distribute files to every Node.
- **Prototype observations:** Record search terms, version-comparison behavior, provenance checks, uncertainty about current versus target distribution, and the first status interpreted as complete.
- **Candidate automated regression checks:** Tests should verify exact-version selection, provenance visibility, import progress and failure recovery, distinct Catalog and Placement status, activation without implicit Organization grants, and no claim of cluster-wide distribution from a controller-local import.

### S4: Organization access and API credentials

- **Contract and maturity:** `SPEC.md` sections 6.6, 7.2.2 through 7.2.3, 7.4a, and 10.2 through 10.4 define current Organization, Model grant, Portal User, API Key, API Token, and authorization behavior, while Workspace remains only a research label.
- **Persona:** The Department Operator grants appropriate Organization access and the Application Developer completes credential and API use.
- **Starting state:** An exact Model is active in the Catalog, but the Organization has no enabled Model grant and the developer has no usable bearer credential.
- **Task prompt:** Give one application the minimum access required to discover and call the approved Model without granting cluster administration.
- **Allowed authority:** A `tenant_admin` may manage Organization-scoped model access and credentials within the accepted surface.
  A tenant-direct API Key may discover and invoke granted Models as the Tenant principal, while a service-account-owned API Token may do so only when its enabled API Client has tenant-scoped `inference_client` access.
  Separately, an Application Developer signed in as an Organization-scoped Portal User may manage only their own portal-minted tenant-direct API Keys.
- **Success evidence:** The exact Model appears in `/v1/models` only after an enabled Organization grant, the bearer credential is shown once and stored safely, the effective principal and Organization are correct, and a request succeeds without cluster-scoped authority.
- **Critical misunderstandings:** The current product-facing term is Organization rather than Workspace, Team is metadata rather than a governance boundary, Portal User is not a Public Inference principal, and Portal User disablement does not automatically revoke minted API Keys.
- **Prototype observations:** Record whether participants can explain who owns the credential, where model access is granted, what one-time output means, and which action is needed to end both portal and key access.
- **Candidate automated regression checks:** Tests should cover deny-by-default model listing, cross-Organization isolation, show-once secrets, disabled API Clients, revoked and expired credentials, Portal User ownership filters, separate Portal User disable and portal-minted API Key revoke, and stable `401` versus `403` behavior.

### S5: Model files, runtime residency, eligibility, and successful inference

- **Contract and maturity:** `SPEC.md` sections 5.5 through 5.8, 6.3 through 6.10, and 7.5 define the state and eligibility boundaries, while a complete Console workflow or remote distribution step should be treated as target behavior wherever the current operator journey reports a gap.
- **Persona:** The Model Curator and On-call Operator establish runtime facts, while the Department Operator and Application Developer establish Organization authorization and request success.
- **Starting state:** The exact Model is active and granted, two active Nodes report different compatibility or capacity evidence, and neither has a loaded placement.
- **Task prompt:** Make the exact Model available with low cold-start risk on suitable capacity and prove that an authorized request can be served.
- **Allowed authority:** An administrator may set accepted cluster placement, routing, and pinning policy, a `tenant_admin` may manage only Organization-scoped keys, quota, and model access that its accepted surface authorizes, and an operator may perform permitted runtime load or diagnostic operations.
  A tenant-direct API Key may discover and invoke granted Models as the Tenant principal, while a service-account-owned API Token may do so only when its enabled API Client has tenant-scoped `inference_client` access.
- **Success evidence:** The participant separately verifies acquisition, authoritative digest verification, cached files, runtime loading, exact-Model placement capacity, lifecycle and health, policy eligibility, Organization authorization, scheduler selection, dispatch-time revalidation, and a successful response.
- **Critical misunderstandings:** Desired placement is not observed state, downloaded is not verified, cached is not loaded, loaded is not eligible, and eligible is not proof that a particular request was authorized or selected.
- **Prototype observations:** Record whether progress and failures remain attributable to files, verification, runtime, policy, capacity, or authorization, and whether long-running steps expose safe resume behavior.
- **Candidate automated regression checks:** Tests should exercise every Placement transition, checksum mismatch, insufficient disk or memory, incompatible runtime, stale observation, capacity exhaustion, access denial, selection evidence, and the final successful inference path.

### S6: Model-first diagnosis

- **Contract and maturity:** `SPEC.md` sections 5.5 through 5.8, 6.3, and 7.3.5 define eligibility and scheduler evidence, while the reciprocal Model-first Console workflow remains a prototype target until its public seams and browser behavior are implemented.
- **Persona:** The On-call Operator begins from the exact Model and may consult the Model Curator when artifact or compatibility evidence is ambiguous, while an Application Developer or separately authorized Public Inference principal performs the recovery request.
- **Starting state:** Requests fail for one exact Model, one active Node has a cached placement that failed to load, one has a loaded placement but is cordoned, and one has compatible cold capacity without files.
- **Task prompt:** Starting from the Model, identify a safe recovery path and state the evidence required before declaring the incident resolved.
- **Allowed authority:** The operator may inspect scheduler and placement evidence and perform permitted runtime operations, but admin-only policy, access, admission, and destructive changes require an authorized handoff.
- **Success evidence:** The operator preserves exact-version identity, distinguishes files, runtime, lifecycle, eligibility, and authorization, selects viable capacity, observes any acquisition and load, and obtains a fresh request result from an Application Developer or separately authorized Public Inference principal together with scheduler evidence.
- **Critical misunderstandings:** A cached failed placement is not ready, a loaded cordoned placement is not schedulable, cold capacity is not guaranteed to load, and changing desired residency is not recovery by itself.
- **Prototype observations:** Record whether the participant can reach the responsible Node, compare candidates, interpret stable reason codes, and return to the same Model context without losing the incident narrative.
- **Candidate automated regression checks:** Tests should verify exact-version preservation across drill-ins, reciprocal links, rejected and skipped candidate reasons, policy-versus-state labels, load failure recovery, and a post-recovery request using an eligible selected Node.

### S7: Node-first diagnosis

- **Contract and maturity:** `SPEC.md` sections 4.2 through 4.6, 5.5 through 5.8, 6.3, and 7.3.5 define Node, placement, and scheduler facts, while the reciprocal Node-first Console workflow remains a prototype target until implemented.
- **Persona:** The On-call Operator begins from a degraded or unexpectedly idle Node and consults the Node Host Custodian for host-local failures.
- **Starting state:** One Node is active but cannot serve an expected exact Model because its files, runtime, policy, or capacity evidence is incomplete.
- **Task prompt:** Starting from the Node, determine why it is not receiving the expected workload and reconcile the answer with the Model view.
- **Allowed authority:** The operator may inspect Node lifecycle, health, freshness, transport, runtime, placements, capacity, and scheduler explanations, while host-local repair stays with the custodian and admin-only mutation stays with an administrator.
- **Success evidence:** The Node view and Model view report the same exact Model and compatible underlying facts, the participant identifies the gating reason, and any recovery produces fresh authenticated evidence before the Node is treated as eligible.
- **Critical misunderstandings:** Node health is not lifecycle, active is not loadedness, aggregate Runtime Endpoint capacity is not per-placement capacity, and qualification evidence is not installed-provider or scheduling authority.
- **Prototype observations:** Record where the reciprocal views disagree, which labels participants conflate, whether stale data is obvious, and whether host-local and Controller-owned responsibilities are clear.
- **Candidate automated regression checks:** Tests should assert reciprocal fact consistency, freshness and source labels, aggregate-versus-placement capacity, observe-only telemetry, identity mismatch behavior, and safe omission when evidence is unavailable.

### S8: Unauthorized and degraded developer access

- **Contract and maturity:** `SPEC.md` sections 7.2.2 through 7.2.3, 7.4a, and 10.2 through 10.4 define the current authentication, authorization, Portal, and Organization-isolation expectations used by this scenario.
- **Persona:** The Application Developer diagnoses the client-visible failure and the Department Operator handles any authorized Organization-side correction.
- **Starting state:** The developer may have an invalid, revoked, expired, or wrong-Organization bearer credential, a valid API Token owned by a disabled API Client, a Portal session ended by Portal User disablement, or a request for an active Model that lacks an enabled Organization grant.
- **Task prompt:** Determine why the application cannot call the Model and recover without exposing credential or cross-Organization information.
- **Allowed authority:** The developer may inspect their own Portal and client output, mint and revoke only their own portal-minted tenant-direct API Keys, and retry with a bearer path authorized for Public Inference.
  Recovery from API Client Disablement requires tenant administration to re-enable the intended API Client or provision a service-account-owned API Token under an enabled API Client, while cluster changes require operator or admin authority.
- **Success evidence:** The participant distinguishes authentication from authorization and runtime availability, replaces or corrects only the failed layer, verifies `/v1/models`, and completes a successful request with no cross-Organization disclosure.
- **Critical misunderstandings:** A `401` is not a Model-placement failure, a `403` for a valid API Token owned by a disabled API Client is not an invalid secret, disabling a Portal User does not revoke previously minted tenant-direct API Keys, and an empty visible Model list does not prove the Catalog is empty.
- **Prototype observations:** Record whether generic external errors remain actionable through safe next steps, whether participants seek unauthorized Console access, and whether they understand which role must fix each cause.
- **Candidate automated regression checks:** Tests should cover `401 invalid_api_key`, `403 forbidden`, `403 model_not_authorized`, indistinguishable cross-Organization Portal failures, no secret echo, no unauthorized mutation, and success after the minimum scoped correction.

### S9: Partial inference failure, bounded retry, and recovery

- **Contract and maturity:** `SPEC.md` sections 3.6, 5.8 through 5.10, 7.3.4, and 12 define current retry, timeout, failure, and recovery invariants, while their complete Console timeline presentation remains a prototype or implementation-specific concern.
- **Persona:** The On-call Operator diagnoses the request while the Application Developer decides whether an idempotent client retry is appropriate.
- **Starting state:** A request encounters Node loss, worker crash, model-load failure, timeout, or Controller restart before or after Output Commitment, with another candidate sometimes available.
- **Task prompt:** Determine whether Orchard may retry, whether the client should retry, and what proves that no unresolved execution is being treated as free capacity.
- **Allowed authority:** Orchard may perform at most the contract-authorized automatic alternate attempt, the operator may use permitted cancel or retry surfaces, and the developer may retry only within the public idempotency and output-commitment contract.
- **Success evidence:** The participant identifies attempt boundaries, Output Commitment, deadline, selected and excluded Nodes, capacity release or quarantine, stable failure mapping, and one terminal request outcome.
- **Critical misunderstandings:** Retryability does not authorize replay after output, a new attempt does not extend the absolute deadline, and unresolved cancellation must not release or reallocate capacity as if execution ended cleanly.
- **Prototype observations:** Record whether the timeline explains automatic versus operator versus client retry, whether partial output changes the decision, and whether quarantine or fail-closed state is visible without exposing internal errors.
- **Candidate automated regression checks:** Tests should cover pre-commit alternate retry, no retry after Output Commitment, caller disconnect, absolute timeout, one automatic alternate attempt with two total attempts maximum, previous-node exclusion, unresolved execution quarantine, idempotency mismatch, and one terminal state.

### S10: Accepted destructive actions and deletion hypotheses

- **Contract and maturity:** `SPEC.md` sections 4.4, 6.8 through 6.10, 7.3.1, and 11.9 define accepted action-specific lifecycle, unload, pinning, and preview requirements, while manual remote Model-file deletion, manual eviction, and Catalog deletion remain research hypotheses until separately accepted.
- **Persona:** The On-call Operator previews permitted runtime operations, while an administrator performs admin-only decommission or pinning actions and evaluates any future deletion prototype.
- **Starting state:** A Node or Model Placement consumes resources, may have active requests, and may also be protected by pinning, policy, trust, or audit requirements.
- **Task prompt:** Reduce resource use or remove the target safely while preserving the distinction between unloading runtime memory, evicting files, changing desired policy, retiring Catalog state, and decommissioning a Node.
- **Allowed authority:** The participant may execute only actions granted by their Access Level after the accepted contract's Action Preview, action-specific confirmation requirements, and applicable drain or active-request gates, and a prototype must not execute unresolved manual eviction or deletion behavior.
- **Success evidence:** For an accepted action, the preview identifies the exact target, blockers, warnings, stable consequence codes, active work, policy effects, audit outcome, and recovery limits, while a deletion prototype succeeds only by exposing unresolved decisions without mutating product state.
- **Critical misunderstandings:** Unload does not delete files, eviction does not retire the Catalog entry, a one-time operation does not necessarily change desired policy, Cancel Drain leaves the Node cordoned, and Decommission is not Maintenance.
- **Prototype observations:** Record whether the participant reads blockers, understands irreversibility, distinguishes immediate from durable effects, and can predict the resulting state before confirmation.
- **Candidate automated regression checks:** Tests should verify side-effect-free previews, non-bypassable blockers, only the confirmation requirements fixed for that action, active-request and pinned-placement protections where applicable, audit atomicity, correct post-state, and no executable delete or manual-evict control for behavior that lacks an accepted contract.

### S11: Security, isolation, and audit review

- **Contract and maturity:** `SPEC.md` sections 7.4a and 10.8 through 10.10 define current secret, Portal, audit, and data-governance behavior, while a dedicated read-only reviewer role or export surface is not currently defined.
- **Persona:** The Security and Compliance Reviewer leads a read-only review with evidence supplied by the relevant Operator or administrator.
- **Starting state:** A workflow includes Portal invitation, portal-minted API Key mint or revoke, Model access change, Node Admission, or a destructive operation across more than one Organization.
- **Task prompt:** Prove who could do what, what changed, what was retained, and what sensitive material was excluded without mutating the system.
- **Allowed authority:** The reviewer receives only approved read-only evidence, and any additional query or export must preserve tenant scope, capture policy, redaction, and least privilege.
- **Success evidence:** The evidence links actor type, scope, target, decision, timestamp, result, and audit reference while excluding plaintext secrets, invite URLs, password material, raw request content outside policy, local paths, and another Organization's identities.
- **Critical misunderstandings:** Portal User provenance is not Bearer ownership, a hash is not permission to reveal a secret, sanitized omission is not verified absence, and successful mutation without atomic audit evidence is not compliant success.
- **Prototype observations:** Record which evidence reviewers cannot find, which terms imply more authority than they carry, and whether the interface distinguishes redaction, unavailability, not applicable, and verified absence.
- **Candidate automated regression checks:** Tests should cover closed audit allowlists, transactional audit failure, tenant-scoped queries, unsafe-key redaction, generic external errors, one-time secret omission, capture-mode boundaries, and read-only evidence panels without execute controls.

### S12: Department Operator and Node Host Custodian handoff

- **Contract and maturity:** `SPEC.md` sections 4.1 through 4.4 and 10.5 define the trust boundaries, while `docs/operator-journey.md` defines the end-to-end handoff as target product intent and leaves the protected bundle-transfer mechanism open.
- **Persona:** The Department Operator owns the capacity need and acceptance criteria, while the Node Host Custodian owns the target machine and an administrator retains cluster admission authority.
- **Starting state:** The department needs more capacity, but the Department Operator cannot access the target machine and the custodian cannot access Organization or cluster administration.
- **Task prompt:** Exchange the minimum protected information needed to add the machine, then return enough evidence for the department and administrator to continue without sharing credentials or extending either participant's authority.
- **Allowed authority:** The Department Operator may describe the capacity requirement and initiate the capacity request or handoff, a separately authorized administrator provisions the Node and issues its enrollment authority, and the custodian may handle the protected bundle and machine-local steps.
  Neither the Department Operator nor the custodian may admit the Node without separate admin authority.
- **Success evidence:** The outgoing handoff names the target machine, trusted Controller identity, protected artifact, exact execution location, expiry, expected registration result, and safe failure route, while the returning handoff contains stable non-secret Node identity and registration evidence rather than credentials, local paths, or raw logs.
- **Critical misunderstandings:** A copied bundle is not a general installation package, local administrator authority is not cluster authority, registration does not imply admission, and no specific protected transfer medium is product-approved while the transfer mechanism remains unresolved.
  A study should evaluate the participant against the study-specified mechanism, and secret-bearing screenshots, recordings, or transcripts must not be persisted as study or repository evidence.
- **Prototype observations:** Record whether each participant knows when ownership changes, what may be copied, what must remain secret, how to recognize stale instructions, and which role is responsible for the next action after success or failure.
- **Candidate automated regression checks:** Tests should verify role-specific instructions, show-once and expiring material, no secret in URLs or persistent page state beyond the accepted contract, copyable non-secret identifiers, safe resume guidance, explicit handoff state, and admission controls unavailable to the custodian.

## Progression from research to regression

### Concept testing

Use low-fidelity flows to test nouns, state distinctions, authority boundaries, expected next actions, and what evidence participants demand.
Ask participants to predict outcomes before revealing the next screen.
Do not count an answer as wrong when it depends on an unresolved contract.
Do count it as critical confusion when a participant grants authority from installation, observation, Portal login, Catalog activation, or desired policy alone.

### Clickable prototypes

Use thin end-to-end paths with believable starting state, delayed operations, denied actions, partial failures, retry, recovery, and cross-role handoffs.
Label simulated or target-only states as prototype behavior so the prototype cannot be cited as implementation evidence.
Instrument first action, path changes, help requests, confirmation behavior, and incorrect declarations of success.
Include keyboard focus, non-color status, reduced-motion behavior, narrow viewport, stale data, and long-running progress where they affect the scenario.

### Moderated testing

Recruit or assign participants by real task exposure and authority rather than job title or demographics.
Start from the same defined state, give the task prompt without vocabulary coaching, and ask the participant to think aloud.
Probe what the participant believes happened, what remains uncertain, who must act next, and what evidence would change their conclusion.
Capture synthesized observations without committing raw transcripts, participant data, machine paths, or recordings to the repository.

### Pre-release product testing

Run the scenario against the actual supported topology, authenticated roles, current failure behavior, and release-quality packaging applicable to the claim.
Replace prototype assumptions with observed product evidence and record every current-versus-target gap.
Inject authorized failures at the boundary under test, including stale observations, denied access, expired secrets, interrupted transfers, load failure, capacity exhaustion, and partial execution.
End operational journeys with a real inference result when the claim is end-to-end readiness.
Keep sanitized execution evidence in the approved issue, pull request, qualification record, or protected evidence store rather than in this guide.

### Browser-level regression coverage

Automate only behavior fixed by `SPEC.md`, accepted decisions, accepted OpenSpec changes, and implemented public seams.
Map each stable critical misunderstanding to an assertion about visible text, accessible semantics, control availability, or server-enforced authorization.
Prefer public-interface and LiveView tests that verify both rendered affordance and mutation denial.
Keep state-source and freshness assertions separate from color and layout assertions.
Retain moderated testing for comprehension, handoff quality, and evidence interpretation that browser automation cannot prove.

## Study interpretation and promotion

A study passes only when participants complete the task within their authority and cite the required evidence without a critical misunderstanding.
Repeated confusion should trigger one focused prototype revision and a targeted terminology or contract review rather than another broad visual redesign.
A finding that changes behavior, authority, persistence, API shape, security, Node lifecycle, scheduling, packaging, or Model lifecycle requires the repository's normal contract process before implementation.
Promote accepted durable conclusions into `SPEC.md`, a decision record, accepted OpenSpec materials, product docs, tests, or code owned by the relevant change.
Do not promote raw research artifacts, participant data, prompt exports, local evidence, or tool identifiers.

## Open research questions

These questions are not product decisions and must not be used as regression expectations until accepted by the appropriate authority.

1. Should a future product-facing Workspace label replace Organization as the one-to-one Tenant projection, and how would routes, audit language, Portal URLs, CLI output, and compatibility behave during that change?
2. What durable resource owns placement preference, what targets may it select, and what precedence applies among on-demand, cached, loaded, pinned, prewarmed, evicted, and one-time operations?
3. What is the approved protected transfer and resumability model for Node Enrollment Bundles across browser, native app, CLI, and air-gapped environments?
4. How should existing installs change Install Role, and who owns safe Node Identity Root handover during repair or machine administration?
5. What packaged multi-machine acceptance evidence is required before the certificate-backed production join journey is described as supported?
6. What precise identity and evidence should the Console use when Model Placement, Artifact Bundle digest, Node, and future multiple Runtime Endpoints intersect?
7. What previews, permissions, audit, retry, partial-failure, and reacquisition semantics are required before remote Model-file deletion or Catalog deletion is exposed?
8. What dedicated read-only access or export contract, if any, should support Security and Compliance Review without granting operator mutation authority?
