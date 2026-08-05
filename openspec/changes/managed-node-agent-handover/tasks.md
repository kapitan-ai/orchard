## 1. Canonical Lifecycle Exclusion

- [ ] 1.1 Implement one interoperable exclusive kernel advisory lock protocol on `/Library/Application Support/Orchard/support/.app-lifecycle.lock` for Orchard.app, PKG, managed recovery, and Node Agent start eligibility paths.
- [ ] 1.2 Retain the same privileged owner's kernel lock continuously from before relaunch prevention through exact exit or proven absence, active activation and protected mutation, start policy, and terminal reporting.
- [ ] 1.3 Prevent lock ownership transfer and prevent descriptor inheritance by child processes and the replacement Node Agent.
- [ ] 1.4 Make normal owner completion close the descriptor, owner death rely on operating-system lock release, and contention perform no managed mutation or Node Agent start.
- [ ] 1.5 Keep persistent transaction or rendezvous metadata diagnostic and recoverable without treating it as exclusion ownership or an independent stale lock.

## 2. PKG Inactive Staging And Active Activation

- [ ] 2.1 Change PKG payload layout so Apple Installer places signed content only into an inactive incoming staging root that the running Node Agent cannot resolve, load, or execute.
- [ ] 2.2 Make `preinstall` perform only non-active preflight or staging preparation and remove its Node Agent stop, relaunch-prevention, and active lifecycle mutation behavior.
- [ ] 2.3 Implement one privileged active handover owner that validates staged payload and performs activation and protected mutation under the canonical lock.
- [ ] 2.4 Make `postinstall` synchronously invoke that owner and propagate its terminal result before completing the package operation.
- [ ] 2.5 Preserve safe direct `/usr/sbin/installer -pkg ... -target /` operation without requiring an Orchard-specific outer wrapper.
- [ ] 2.6 Define incoming staging cleanup and repeated-install behavior without allowing staged content or stale metadata to become active or confer ownership.

## 3. Relaunch Prevention And Exact Process Proof

- [ ] 3.1 Prevent launchd relaunch with verified job-domain control such as `bootout` followed by proof that the Node Agent job is unloaded.
- [ ] 3.2 Ensure relaunch prevention does not edit or delete the protected launchd plist before the handover proof gate.
- [ ] 3.3 Capture process-instance evidence that identifies the exact outgoing managed Node Agent and cannot be satisfied by only a reusable PID or launchd label.
- [ ] 3.4 Add a bounded wait that proves either exact outgoing-instance exit or managed-process absence before active payload activation or protected lifecycle mutation.
- [ ] 3.5 Fail closed without active mutation or Node Agent start on relaunch-prevention failure, process ambiguity, unprovable absence, timeout, or exclusion loss.

## 4. Path-Specific Start Policies

- [ ] 4.1 Preserve Orchard.app restoration of previously loaded services still selected by the resulting role after coherent success.
- [ ] 4.2 Keep every successful PKG fresh install and upgrade stopped without automatic start or prior-loaded-state restoration.
- [ ] 4.3 Route the supported later PKG start through `orchardctl start` and make Node Agent start eligibility verify coherent installed state under the canonical exclusion boundary.
- [ ] 4.4 Reject `orchardctl start` when unresolved handover uncertainty or incoherent installed state requires managed recovery.

## 5. Orchard.app Rollback And Managed Recovery

- [ ] 5.1 Route app-owned Node Agent install, update, uninstall, and role-transition paths through the complete shared handover ordering.
- [ ] 5.2 Preserve the unconditional Orchard.app attempt to roll back prior payload, command links, launchd plists, role marker, and loaded-service state after every post-mutation failure.
- [ ] 5.3 Report rollback success separately from the triggering failure and classify incomplete or unverifiable rollback as uncertain and stopped.
- [ ] 5.4 Implement managed Orchard.app and PKG recovery by rerunning the applicable lifecycle under the canonical exclusion boundary.
- [ ] 5.5 Reauthorize start after recovery only when exact exit or managed-process absence and coherent installed state are proven, then apply the app or PKG start policy.
- [ ] 5.6 Keep blind `launchctl` kickstart, direct binary launch, and manual same-root start unsupported while uncertainty remains.

## 6. Peer Grant Store Lock Boundary

- [ ] 6.1 Keep the `Orchard.Node.BeamPeerGrantStore` lock scoped to one grant install or load operation and its atomic publication.
- [ ] 6.2 Confirm the Peer Grant Store Lock is not reused, transferred, or broadened into Managed Lifecycle Exclusion or a Node Identity Root Lease.

## 7. Verification And Handoff

- [ ] 7.1 Add cross-path contention coverage for Orchard.app, direct PKG install, managed recovery, and `orchardctl start` against the canonical lock.
- [ ] 7.2 Add PKG integration coverage proving `preinstall` leaves the active Node Agent installation untouched and no running process resolves, loads, or executes the inactive incoming staging root.
- [ ] 7.3 Add direct installer, installer-abort-before-postinstall, repeated-install, and postinstall-owned activation coverage.
- [ ] 7.4 Add lock lifetime coverage for one continuous owner, no descriptor inheritance, normal close, owner crash release, retry after release, and surviving metadata that does not confer ownership.
- [ ] 7.5 Add ordering coverage proving verified launchd `bootout` precedes exact exit or absence proof without protected plist mutation and that proof precedes every active mutation.
- [ ] 7.6 Add failure coverage for relaunch-prevention failure, process-identification ambiguity, unprovable absence, bounded timeout, exclusion loss, owner death, activation uncertainty, and incoherent installed state.
- [ ] 7.7 Add PKG coverage proving no automatic start or prior-loaded-state restoration after fresh install, upgrade, or successful managed recovery, followed by eligible manual `orchardctl start`.
- [ ] 7.8 Add Orchard.app coverage proving full rollback is always attempted after post-mutation failure, prior loaded state returns after successful rollback, and incomplete or unverifiable rollback remains stopped and uncertain.
- [ ] 7.9 Add managed recovery coverage proving no start is reauthorized before exit or absence and coherent state are established under the shared boundary.
- [ ] 7.10 Add acceptance coverage showing Controller `N` and Node Agent `N-1` compatibility uses serialized activation or replacement without same-root overlap.
- [ ] 7.11 Run the applicable Swift, packaging-script, direct installer, OpenSpec, and repository quality workflows and record exact results in the implementation pull request.
- [ ] 7.12 After archive or sync, run `OPENSPEC_TELEMETRY=0 mise exec -- npm run openspec -- validate --all --strict --no-interactive` and review generated main-spec prose for placeholders such as `Purpose TBD`.
