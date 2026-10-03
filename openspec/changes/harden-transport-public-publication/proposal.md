## Why

`orchardctl transport enable-local-https` publishes the generated local CA certificate and the endpoint metadata sidecar into the support-root `public/` directory so non-root status and enrollment readers can find them.
The current implementation generates TLS material before it validates the public path, creates directories with `mkdir -p` and repairs modes later with `chmod`, writes pathname temporary files beside the final names, and rolls back the endpoint file by pathname.
Under a searchable support root those steps leave intervals in which another local UID can traverse, pre-create, or hold descriptors on publication entries, and a rollback can overwrite or remove an entry the command did not create.

## What Changes

- Validate the support-root ancestry, support root, existing public directory, and existing public files through a host-native helper before TLS generation; unsafe paths refuse unchanged and cause no TLS side effects.
- Establish the support-root ancestry component by component without following symlinks, and accept only components owned by root or the effective UID that are not group- or other-writable, except root-owned sticky directories.
- Refuse any extended or default ACL, setgid directory, unqualified filesystem, or ownership-ignoring mount on the publication path under a bounded strict policy, and refuse when ACL or filesystem inspection fails.
- Create a private random staging directory with an explicit `0700` creation mode under the validated support root, without changing the process umask and without later mode repair.
- Build the complete CA certificate and encoded endpoint metadata inside the stage, widen file and directory modes only after contents are complete, and publish either the whole completed directory or staged per-file renames.
- Serialize cooperative publishers, bind snapshots and rollback to descriptor identity, retain foreign substitutions and residue, and never delete recursively.
- Add an explicit host-native publication helper with source, builder, staging, and test-helper ownership that keeps portable Mix compilation free of native builds.

## Capabilities

### New Capabilities

- `local-ca-publication`: Defines safe publication of generated local-CA public artifacts and endpoint metadata by `orchardctl transport enable-local-https`, and the explicit host-native helper boundary that implements it.

### Modified Capabilities

None.

## Impact

- `SPEC.md` §10.7 gains a concise normative paragraph for local-CA public artifact publication; ADR 0036 records the decision and its limits.
- `orchardctl transport enable-local-https` refuses paths it previously repaired, such as group-writable, ACL-bearing, setgid, symlinked, or unqualified-filesystem public paths.
- Contributors need a host C compiler for Linux source tests; Darwin keeps the Xcode Command Line Tools requirement.
- No change to transport modes, certificate provenance, TLS or mTLS protocols, Runtime Endpoints, grants, authentication, or distribution assembly.
