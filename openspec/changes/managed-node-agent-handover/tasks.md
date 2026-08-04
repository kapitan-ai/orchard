## 1. Shared Lifecycle Exclusion

- [ ] 1.1 Implement one managed lifecycle exclusion primitive used by both Orchard.app and PKG Node Agent operations for the complete shutdown-proof, mutation, and replacement-start interval.
- [ ] 1.2 Make failure to acquire or retain the shared exclusion boundary fail closed before managed mutation or replacement start.
- [ ] 1.3 Keep BEAM Peer Grant storage locks operation-scoped and separate from the lifecycle exclusion primitive.

## 2. Exact Outgoing-Process Exit Proof

- [ ] 2.1 Capture process-instance evidence that identifies the exact outgoing managed Node Agent and cannot be satisfied by only a reusable PID or launchd label.
- [ ] 2.2 Prevent launchd relaunch before requesting managed shutdown.
- [ ] 2.3 Add a bounded wait that proves either the captured outgoing instance exited or that no managed Node Agent instance is running before any Node Agent payload, launchd plist, command symlink, role marker, or Node Identity Root mutation.
- [ ] 2.4 Gate replacement start on a satisfied handover gate and completion of the required managed mutation.
- [ ] 2.5 Fail closed without mutation or replacement start when relaunch prevention is unavailable, or when neither exact outgoing-instance exit proof nor proven absence of a managed Node Agent instance is established within the bound, including ambiguous process identification and ambiguous absence.

## 3. Orchard.app Integration

- [ ] 3.1 Route managed Orchard.app Node Agent install, update, uninstall, and role-transition paths through the shared handover boundary and ordering.
- [ ] 3.2 Preserve the app lifecycle's prior-state restoration obligations after post-mutation failure when restoration can be proven.
- [ ] 3.3 Suppress automatic Node Agent restart when app mutation or restoration state is uncertain.

## 4. PKG Integration

- [ ] 4.1 Route PKG Node Agent install, update, uninstall, and role-transition paths through the same shared handover boundary and ordering.
- [ ] 4.2 Preserve PKG's existing supported unattended and offline/manual installation behavior without claiming transactional rollback.
- [ ] 4.3 Suppress automatic Node Agent restart when PKG mutation or restoration state is uncertain.

## 5. Verification And Handoff

- [ ] 5.1 Add cross-path concurrency coverage proving overlapping Orchard.app and PKG lifecycle attempts cannot enter the managed Node Agent handover together.
- [ ] 5.2 Add failure-path coverage for relaunch-prevention failure, process-identification failure, exact-instance ambiguity, unprovable absence, bounded exit timeout, exclusion loss, and uncertain mutation or restoration.
- [ ] 5.3 Add ordering coverage proving every listed mutation and replacement start occurs only after exact outgoing-instance exit proof or proven absence of a managed Node Agent instance.
- [ ] 5.4 Add app restoration coverage and PKG non-transactional failure coverage without weakening their shared fail-closed handover invariant.
- [ ] 5.5 Add acceptance coverage showing rolling Controller `N`/Node Agent `N-1` compatibility is exercised through serialized managed shutdown and replacement, never same-root live overlap.
- [ ] 5.6 Confirm direct or manual same-root launches remain unsupported and that no lifetime Node Identity Root Lease, dual lifecycle locks, root migration, automatic repair, transactional PKG rollback, or uncertain-state automatic restart was introduced.
- [ ] 5.7 Run the applicable Swift, packaging-script, OpenSpec, and repository quality workflows and record exact results in the implementation pull request.
- [ ] 5.8 After archive or sync, run `OPENSPEC_TELEMETRY=0 mise exec -- npm run openspec -- validate --all --strict --no-interactive` and review generated main-spec prose for placeholders such as `Purpose TBD`.
