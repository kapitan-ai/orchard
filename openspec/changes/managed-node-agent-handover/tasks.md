## 1. Canonical Lifecycle Exclusion

- [ ] 1.1 Implement one interoperable exclusive kernel advisory lock protocol on `/Library/Application Support/Orchard/support/.app-lifecycle.lock` for Orchard.app, PKG, managed recovery, and Node Agent start eligibility paths.
- [ ] 1.2 Retain the same privileged owner's kernel lock continuously from initial evidence and durable suppression through immediate pre-`bootout` observation, every captured-instance exit or affirmative absence, active activation and protected mutation, start policy, and terminal reporting.
- [ ] 1.3 Prevent lock ownership transfer and prevent descriptor inheritance by child processes and the replacement Node Agent.
- [ ] 1.4 Make normal owner completion close the descriptor, owner death rely on operating-system lock release, and contention perform no managed mutation or Node Agent start.
- [ ] 1.5 Durably record required handover or recovery operation identity and phase, staging generation when applicable, prior active path and start policy as needed, and intended mutation before changing start eligibility or any other protected active state.
- [ ] 1.6 Mark no-start handover or recovery evidence terminal coherent only after installed-state verification, use distinct evidence for later start attempts, and keep missing, incomplete, or uncertain evidence from authorizing start without letting it own or block the canonical lock.

## 2. PKG Inactive Staging And Active Activation

- [ ] 2.1 Change PKG payload layout so Apple Installer places authenticated and signed content only into an inactive incoming staging root that the running Node Agent cannot resolve, load, or execute.
- [ ] 2.2 Make `preinstall` perform only non-active preflight or staging preparation and remove its Node Agent stop, relaunch-prevention, and active lifecycle mutation behavior.
- [ ] 2.3 Implement one privileged active handover owner that binds activation to exactly one complete authenticated and signed generation in a unique immutable or equivalently identity-stable namespace and rejects invalid content before relaunch prevention or active mutation.
- [ ] 2.4 Make `postinstall` synchronously invoke that owner and propagate its terminal result before completing the package operation.
- [ ] 2.5 Preserve safe direct `/usr/sbin/installer -pkg ... -target /` operation without requiring an Orchard-specific outer wrapper.
- [ ] 2.6 Revalidate the bound pathname or descriptor identity, manifest, signature, complete file set, content integrity, trust, and target immediately before atomic activation, and make concurrent or repeated installers unable to replace or modify the bound generation.
- [ ] 2.7 Define incoming generation cleanup and repeated-install behavior without allowing staged content or recovery evidence to mix generations, become active without validation, or confer exclusion ownership.

## 3. Relaunch Prevention And Exact Process Proof

- [ ] 3.1 Establish durable start suppression after initial operation evidence and before final process observation.
- [ ] 3.2 Under suppression and immediately before `bootout`, capture and durably record stable non-reusable evidence for exactly one outgoing instance or affirmatively prove no managed instance exists, and reject additional, replacement, or identity-unstable processes.
- [ ] 3.3 Prevent launchd relaunch with verified job-domain control such as `bootout` followed by proof that the Node Agent job is unloaded without editing or deleting the protected plist before the handover proof gate.
- [ ] 3.4 Add a bounded wait after `bootout` that proves every captured outgoing instance exited, while accepting absence only from the immediate observation under suppression.
- [ ] 3.5 Fail closed without active mutation or Node Agent start on failed final observation, relaunch-prevention failure, process ambiguity or identity change, unproven captured-instance exit, unproven absence, timeout, or exclusion loss.

## 4. Path-Specific Start Policies

- [ ] 4.1 Implement a protected Managed Node Agent Start Eligibility State checked by the managed launch path before execution and preserved across owner death, reboot, launchd domain reload, and `KeepAlive` retry.
- [ ] 4.2 Ensure plist publication or loading never authorizes launch and keep every successful PKG fresh install and upgrade suppressed without automatic start or prior-loaded-state restoration.
- [ ] 4.3 Route Orchard.app loaded-state restoration after coherent success or successful required rollback through a distinct managed start attempt under the canonical lock.
- [ ] 4.4 Route the supported later PKG start through `orchardctl start`, which verifies prior terminal coherent evidence and installed state, records distinct non-terminal start-attempt evidence, verifies the job remains unloaded, and creates operation-bound one-shot authorization for one explicit bootstrap.
- [ ] 4.5 Verify the intended Node Agent instance and only then atomically mark the start attempt terminal coherent and enable durable eligibility, while invalidating authorization, keeping or restoring suppression, and preventing provisional continuation on every failure or owner-death path.
- [ ] 4.6 Reject `orchardctl start` and retain suppression when prior evidence is missing, incomplete, uncertain, or non-terminal or when installed state requires managed recovery.

## 5. Orchard.app Rollback And Managed Recovery

- [ ] 5.1 Route app-owned Node Agent install, update, uninstall, and role-transition paths through the complete shared handover ordering.
- [ ] 5.2 Preserve the unconditional Orchard.app attempt to roll back prior payload, command links, launchd plists, role marker, and loaded-service state after every post-mutation failure.
- [ ] 5.3 Report rollback success separately from the triggering failure and classify incomplete or unverifiable rollback as uncertain and stopped.
- [ ] 5.4 Implement managed Orchard.app and PKG recovery by rerunning the applicable lifecycle under the canonical exclusion boundary.
- [ ] 5.5 Let recovery acquire the canonical lock despite missing, incomplete, or uncertain evidence, record or reconcile initial evidence, reestablish durable suppression before final observation, and permit a later managed start only after every captured-instance exit or affirmative absence under suppression, coherent installed state, and terminal coherent handover or recovery evidence are proven.
- [ ] 5.6 Keep blind `launchctl` kickstart, direct binary launch, and manual same-root start unsupported while uncertainty remains.

## 6. Peer Grant Store Lock Boundary

- [ ] 6.1 Keep the `Orchard.Node.BeamPeerGrantStore` lock scoped to one grant install or load operation and its atomic publication.
- [ ] 6.2 Confirm the Peer Grant Store Lock is not reused, transferred, or broadened into Managed Lifecycle Exclusion or a Node Identity Root Lease.

## 7. Verification And Handoff

- [ ] 7.1 Add cross-path contention coverage for Orchard.app, direct PKG install, managed recovery, and `orchardctl start` against the canonical lock.
- [ ] 7.2 Add PKG integration coverage proving `preinstall` leaves the active Node Agent installation untouched and no running process resolves, loads, or executes the inactive incoming staging root.
- [ ] 7.3 Add direct installer, installer-abort-before-postinstall, repeated-install, authenticated single-generation activation, and partial, stale, mixed-generation, untrusted, ambiguous, replaced, modified, or missing staging rejection coverage.
- [ ] 7.4 Add concurrent repeated-installer coverage proving a bound unique generation remains immutable or equivalently identity-stable and is fully revalidated immediately before atomic activation.
- [ ] 7.5 Add lock and evidence coverage for one continuous owner, no descriptor inheritance, normal close, owner crash release, retry after release, required durable evidence before protected mutation, distinct start-attempt evidence, terminal coherent marking after applicable verification, and surviving evidence that does not confer or block ownership.
- [ ] 7.6 Add ordering coverage proving initial evidence and suppression precede final process observation, stable exact capture or affirmative absence occurs under suppression immediately before verified `bootout`, every captured-instance exit follows `bootout`, and the proof gate precedes protected plist mutation and every other active mutation.
- [ ] 7.7 Add failure coverage for an outgoing process exit and `KeepAlive` replacement attempt around suppression, relaunch-prevention failure, failed final observation, additional or identity-changing processes, unproven captured-instance exit, unproven absence, bounded timeout, exclusion loss, owner death, missing or incomplete evidence, activation uncertainty, and incoherent installed state.
- [ ] 7.8 Add reboot, launchd domain reload, `RunAtLoad`, and `KeepAlive` coverage proving durable suppression prevents launch and plist publication alone cannot authorize the Node Agent.
- [ ] 7.9 Add PKG start coverage proving no automatic start or prior-loaded-state restoration, then proving `orchardctl start` records distinct evidence, creates crash-invalid one-shot authorization, explicitly bootstraps and verifies the intended instance, and atomically records terminal coherent start evidence with durable enabled eligibility.
- [ ] 7.10 Add owner-death and reboot coverage after one-shot authorization but before bootstrap and after bootstrap but before atomic terminal enablement.
- [ ] 7.11 Add Orchard.app coverage proving full rollback is always attempted after post-mutation failure, prior loaded state returns through the managed start-attempt protocol after successful rollback, and incomplete or unverifiable rollback remains suppressed and uncertain.
- [ ] 7.12 Add managed recovery coverage proving missing or uncertain evidence does not block lock acquisition and no later managed start is permitted before suppression, every captured-instance exit or affirmative absence under suppression, coherent state, and terminal coherent handover or recovery evidence are established.
- [ ] 7.13 Add acceptance coverage showing Controller `N` and Node Agent `N-1` compatibility uses serialized activation or replacement without same-root overlap.
- [ ] 7.14 Run the applicable Swift, packaging-script, direct installer, OpenSpec, and repository quality workflows and record exact results in the implementation pull request.
- [ ] 7.15 After archive or sync, run `OPENSPEC_TELEMETRY=0 mise exec -- npm run openspec -- validate --all --strict --no-interactive` and review generated main-spec prose for placeholders such as `Purpose TBD`.
