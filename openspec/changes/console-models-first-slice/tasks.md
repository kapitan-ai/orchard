## 1. Contract and import identity

- [x] 1.1 Document Models navigation and state presentation in docs/DESIGN.md.
- [x] 1.2 Pin imports to selected server-held revisions and reject provider snapshot drift with regression coverage.

## 2. Models journey

- [x] 2.1 Add shared Models navigation, canonical Discover route, and empty catalog handoff.
- [x] 2.2 Add explicit capability filters, search recovery, and Import actions with LiveView coverage.
- [x] 2.3 Display exact catalog version and stored digest with truthful readiness copy.

## 3. Validation

- [x] 3.1 Validate this OpenSpec change strictly and run the required Elixir quality workflow.
- [x] 3.2 Verify the runnable Console in light and dark themes, with collapsed navigation and narrow viewport scrolling.
- [ ] 3.3 On later archive or sync, review generated specs for placeholder prose before accepting them.

## 4. Download management

- [x] 4.1 Add server-scoped job listing and cooperative pause, resume, and cancel controls with a serialized finalization boundary.
- [x] 4.2 Verify partial-file resume, cancellation cleanup, finalization races, and persistent access to download UI across navigation.
- [x] 4.3 Verify cancelled exact-revision restart and terminal history removal across navigation.

## 5. Catalog entry

- [x] 5.1 Make Catalog the primary Models destination with imported records and session activity, preserving exact-job detail and return navigation.
- [x] 5.2 Verify direct entry, return navigation, and narrow layouts; run the applicable quality workflow.
