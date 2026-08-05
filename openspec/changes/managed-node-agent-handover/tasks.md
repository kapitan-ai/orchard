## 1. Canonical Lifecycle Exclusion

- [ ] 1.1 Implement one interoperable exclusive kernel advisory lock protocol on `/Library/Application Support/Orchard/support/.app-lifecycle.lock` for owner-side Orchard.app, PKG, managed recovery, and Node Agent start-attempt paths, and keep the child-side managed launch gate off that lock entirely.
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

- [ ] 3.1 Establish durable start suppression after initial operation evidence and before final process observation by setting eligibility `suppressed`, invalidating any outstanding one-shot authorization, and applying persistent launchd job-domain disablement.
- [ ] 3.2 Under suppression and immediately before `bootout`, capture and durably record stable non-reusable evidence for exactly one outgoing instance or affirmatively prove no managed instance exists, and reject additional, replacement, or identity-unstable processes.
- [ ] 3.3 Prevent launchd relaunch with verified job-domain control such as `bootout` followed by proof that the Node Agent job is unloaded without editing or deleting the protected plist before the handover proof gate.
- [ ] 3.4 Add a bounded wait after `bootout` that proves every captured outgoing instance exited, while accepting absence only from the immediate observation under suppression.
- [ ] 3.5 Fail closed without active mutation or Node Agent start on failed final observation, relaunch-prevention failure, process ambiguity or identity change, unproven captured-instance exit, unproven absence, timeout, or exclusion loss.

## 4. Path-Specific Start And Stop Policies

- [ ] 4.1 Implement a protected Node Agent-only Managed Node Agent Start Eligibility State valued `suppressed`, `one_shot_pending`, or `enabled`, checked by the child-side managed launch path before execution, and preserved across owner death, reboot, launchd domain reload, and `KeepAlive` retry through persistent launchd job-domain disablement plus launch-gate denial.
- [ ] 4.2 Ensure plist publication or loading never authorizes launch, keep every successful PKG fresh install and upgrade leaving all role-selected services stopped with the Node Agent suppressed and no automatic start or prior-loaded-state restoration, and leave other role-selected services on normal supported launchd start behavior without eligibility fencing.
- [ ] 4.3 Route Orchard.app loaded-state restoration after coherent success or successful required rollback through a distinct managed start attempt under the canonical lock.
- [ ] 4.4 Route the supported later PKG start through `orchardctl start`, which verifies prior terminal coherent evidence and installed state, records distinct non-terminal start-attempt evidence, verifies or establishes an unloaded job with no managed Node Agent process running while holding the lock, then lifts job-domain disablement and creates operation-bound single-consumer one-shot authorization for one explicit bootstrap.
- [ ] 4.5 Verify the intended Node Agent instance and only then atomically mark the start attempt terminal coherent and enable durable eligibility, while invalidating authorization, keeping or restoring suppression, and preventing provisional continuation on every failure or owner-death path.
- [ ] 4.6 Reject `orchardctl start` and retain suppression when prior evidence is missing, incomplete, uncertain, or non-terminal or when installed state requires managed recovery.
- [ ] 4.7 Implement the child-side managed launch gate so it acquires, waits on, and inherits no canonical lock descriptor, permits normal operation under `enabled`, denies under `suppressed`, and under `one_shot_pending` permits only an atomic claim of a matching unclaimed one-shot authorization, never reclaiming one or enabling durable eligibility itself.
- [ ] 4.8 Give the one-shot authorization the observable matching components — start-attempt identity, exact non-reusable owner process identity using process id plus kernel start generation or start time, per-bootstrap nonce, intended launchd label, expected active or staged generation and executable identity, eligibility generation, and single-consumer claim state — and require an observably live recorded owner instance so a mid-attempt owner death fails closed without a live actor.
- [ ] 4.9 Implement the provisional child phase so a claimed child records its exact non-reusable identity, adopts no cluster identity, does not serve, observes its exact recorded owner instance with race-safe exit observation and re-verification, exits on owner death or mismatch before acceptance, and serves only after the same owner atomically records terminal coherent evidence and `enabled` eligibility bound to it.
- [ ] 4.10 Implement start-request dispatch per entry state: attempt only from `suppressed`, idempotent success under `enabled` with one verified healthy exact instance, managed recovery normalization for every other `enabled` combination, continuation of `one_shot_pending` only by the exact live recorded owner, and recovery normalization with a new attempt identity otherwise, never releasing the lock with an attempt still pending.

- [ ] 4.11 Route every supported managed Node Agent stop, including `orchardctl stop` and Orchard.app-initiated stops, through the canonical lock for the complete stop.
- [ ] 4.12 Make a managed stop durably set eligibility `suppressed`, invalidate any pending or non-terminal one-shot authorization, and apply persistent launchd job-domain disablement before `bootout`.
- [ ] 4.13 Make a managed stop unload the launchd job and prove exact captured-instance exit or affirmative managed-process absence before releasing the lock, failing closed with suppression retained otherwise.
- [ ] 4.14 Ensure no managed stop leaves eligibility `enabled` or `one_shot_pending`, so a stop followed by a start re-enters the attempt from `suppressed`.

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
- [ ] 7.8 Add reboot, launchd domain reload, `RunAtLoad`, and `KeepAlive` coverage proving persistent job-domain disablement keeps a suppressed Node Agent job from bootstrapping, the launch gate still denies a job that is bootstrapped anyway, and plist publication alone cannot authorize the Node Agent.
- [ ] 7.9 Add PKG start coverage proving every role-selected service is left stopped with no automatic start or prior-loaded-state restoration, that non-Node-Agent services use normal supported launchd start behavior without eligibility fencing, and that `orchardctl start` records distinct evidence, verifies or establishes an unloaded job with no managed Node Agent process, creates crash-invalid one-shot authorization, explicitly bootstraps and verifies the intended instance, and atomically records terminal coherent start evidence with durable enabled eligibility.
- [ ] 7.10 Add owner-death and reboot coverage after one-shot authorization but before bootstrap and after bootstrap but before atomic terminal enablement.
- [ ] 7.11 Add launch-gate coverage proving the gate takes no canonical lock and inherits no descriptor, succeeds while its start owner holds the lock, permits normal operation under `enabled`, denies under `suppressed`, refuses to reclaim a claimed authorization, and never enables durable eligibility itself.
- [ ] 7.12 Add start-precondition coverage proving a start attempt against a suppressed job left loaded by reboot or domain reload boots it out and proves it unloaded with no managed process, fails closed when it can prove neither, and that a concurrent second start attempt creates no authorization and mutates no eligibility.
- [ ] 7.13 Add per-component matching coverage proving the gate denies on a foreign attempt identity, a reused process id with a differing start generation, a stale nonce, a different launchd label, an unexpected active or staged generation or executable identity, a stale eligibility generation, and an already claimed authorization.
- [ ] 7.14 Add owner-liveness coverage proving an owner death between recording `one_shot_pending` and bootstrap leaves the gate denying on liveness alone, including across a reboot that bootstraps the no-longer-disabled job, and that owner death after the atomic terminal transition leaves the accepted instance serving.
- [ ] 7.15 Add provisional-child coverage proving a claimed child adopts no cluster identity and does not serve before acceptance, exits when its recorded owner instance dies or is replaced, and serves only after acceptance bound to its exact identity.
- [ ] 7.16 Add managed stop coverage proving `orchardctl stop` and Orchard.app-initiated stops acquire the lock, set suppression, invalidate outstanding authorization, and apply job-domain disablement before `bootout`, prove exact exit or absence before releasing the lock, fail closed otherwise, and never leave eligibility `enabled` or `one_shot_pending`.
- [ ] 7.17 Add entry-state coverage for a stop-then-start cycle, an idempotent start under `enabled` with one verified healthy instance, recovery normalization from every other `enabled` combination, continuation only by the exact live recorded owner under `one_shot_pending`, and recovery normalization with a new attempt identity otherwise.
- [ ] 7.18 Add Orchard.app coverage proving full rollback is always attempted after post-mutation failure, prior loaded state returns through the managed start-attempt protocol after successful rollback, and incomplete or unverifiable rollback remains suppressed and uncertain.
- [ ] 7.19 Add managed recovery coverage proving missing or uncertain evidence does not block lock acquisition and no later managed start is permitted before suppression, every captured-instance exit or affirmative absence under suppression, coherent state, and terminal coherent handover or recovery evidence are established.
- [ ] 7.20 Add acceptance coverage showing Controller `N` and Node Agent `N-1` compatibility uses serialized activation or replacement without same-root overlap.
- [ ] 7.21 Run the applicable Swift, packaging-script, direct installer, OpenSpec, and repository quality workflows and record exact results in the implementation pull request.
- [ ] 7.22 After archive or sync, run `OPENSPEC_TELEMETRY=0 mise exec -- npm run openspec -- validate --all --strict --no-interactive` and review generated main-spec prose for placeholders such as `Purpose TBD`.
