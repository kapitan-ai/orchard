## 1. Contract

- [x] 1.1 Add the local-CA publication paragraph to `SPEC.md` §10.7 and ADR 0036.
- [x] 1.2 Document helper build prerequisites and test staging in contributor docs.

## 2. Helper

- [x] 2.1 Implement `orchard-transport-publish` with ancestry, filesystem, ACL, staging, publication, rollback, and serialization.
- [x] 2.2 Add explicit Darwin and Linux builders, Make targets, and payload staging.

## 3. CLI

- [x] 3.1 Add a pure `EndpointMetadata.encode/2` and a helper Port client.
- [x] 3.2 Move public-path validation before TLS initialization and publish through the helper.
- [x] 3.3 Validate private `config/`, `controller.env`, and TLS source custody before TLS initialization.
- [x] 3.4 Document legacy `0750 root:admin` config refusal and operator remediation.
- [x] 3.5 Keep the stage `0700` through rename, bound the publisher lock wait, and classify visible and unknown publication states.
- [x] 3.6 Run Transport TLS generation with its temporary directory inside the private stage.

## 4. Validation

- [x] 4.1 Add ExUnit regressions for umasks, unsafe paths, ACLs, filesystems, hardlinks, rollback, concurrency, and helper failure.
- [x] 4.2 Add a second-UID helper validation script to Linux and macOS CI.
- [x] 4.4 Run the second-UID matrix from searchable `0711` roots with sensitivity controls, and drive the production helper's framed protocol as root.
- [ ] 4.3 Run exact-head macOS host validation and independent review.
