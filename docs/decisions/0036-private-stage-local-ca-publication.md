# ADR 0036: Private-stage local-CA public artifact publication

## Status

Accepted

## Context

`SPEC.md` §10.7 lets `direct_https` use explicit local-CA helper output and requires `/ca.crt` to publish only generated local-CA material.
`orchardctl transport enable-local-https` also publishes that CA certificate and the endpoint metadata sidecar into the support-root `public/` directory, which non-root status and enrollment readers read by exact path.
The earlier implementation initialized TLS before checking the public path, created directories with `mkdir -p` and repaired modes with `chmod`, wrote pathname temporary files beside the final names, and rolled back the endpoint by pathname.
With a searchable support root, another local UID could traverse or pre-create entries during those intervals or keep descriptors that outlive the later mode change, and rollback could overwrite or remove an entry the command never created.

ADR 0014 defines protected publication for one-time plaintext credentials.
The public artifacts here are not secret, but the same rules about creation mode, descriptor binding, and identity-checked cleanup apply to keep their contents and names under the publisher's control.

## Decision

Publication runs inside a host-native helper, `orchard-transport-publish`, that the CLI drives over a framed Port for the whole command.

Threat model: other local UIDs, including members of the admin or caller group, are adversaries.
Root, the effective UID, and privileged writers of ancestors or mounts are excluded.

Before TLS initialization the helper:

- opens `/` and each support-root component without following symlinks and requires each to be owned by root or the effective UID, not group- or other-writable unless root-owned and sticky, ACL-free, and, on Darwin, on a mount that honors ownership;
- requires the existing support root, and any existing `public/`, `ca.crt`, and `endpoint.json`, to be caller-owned, not group- or other-writable, not setgid, ACL-free, on one device, and on a qualified filesystem;
- requires an existing `config/` to be caller-owned with no group or other access (`0700`), and an existing `config/controller.env`, `config/tls/`, and TLS source files (`ca.key`, `ca.crt`, `controller.crt`, `controller.key`, `.orchard-tls-meta.json`) to be regular files or directories as expected, not symlinks, caller-owned, not group- or other-writable, ACL-free, and on the support-root device;
- takes an exclusive `flock` on the support-root descriptor, polling for at most 90 seconds and exiting without creating a stage if its client disconnects while it waits;
- creates `.orchard-public-stage-<random>` with `mkdirat(support_fd, leaf, 0700)` and confirms mode, owner, identity, ACL absence, and filesystem afterward.

Qualified filesystems are the explicit profiles below; every other filesystem refuses:

- Darwin: local APFS or HFS that honors ownership, is not a union mount, and reports extended security; ACL presence comes from `filesec_query_property(FILESEC_ACL)`.
- Linux: the ext4-family POSIX ACL model, where both POSIX ACL attributes must report `ENODATA`; the test-only helper also accepts tmpfs for isolated test trees.

Any extended or default ACL refuses, including benign entries, and failed inspection refuses.
Unsafe existing paths are never repaired or stripped.

The private TLS and controller environment writers continue to use pathname operations with intermediate mode changes.
The controller environment writer is safe because the validated ancestry and caller-owned owner-only `config/` mean no other UID can traverse into, create in, or rename within that directory during those intervals; a descriptor another UID opened on `config/` earlier cannot look up entries once the directory is owner-only, because lookups check the directory's current mode.
That argument does not cover `config/tls/`: the TLS writer keeps it at `0750`, so a group member who opened `tls/` while a legacy layout let it traverse `config/` can still look up and create entries through that descriptor after `config/` is narrowed.
Transport therefore runs TLS generation with its temporary directory inside the private stage, which is owner-only from birth and was never reachable by another UID, and renames the finished files into `tls/` on the same device; keys are `0600` before they are renamed, so `tls/` exposes only final public certificates and metadata to such a descriptor.
Standalone `orchardctl tls init` keeps its existing temporary directory beside its output.
The helper keeps `config/` open and confirms its identity again before publication.
This matches the owner-only config directory that `orchardctl env init` already establishes.

The legacy macOS installer creates `config/` and `config/tls/` as `0750` owned by `root:admin`, and `packaging/README.md` documents that layout.
Admin-group traverse on `config/` would let any administrator account reach the TLS writers' temporary-mode windows, so the helper keeps the owner-only requirement and refuses that layout unchanged.
The installer is not changed here because macOS app assembly is paused under `SPEC.md` §11.0.
Before running the command on such a host, an operator reviews who owns `config/` and which group members rely on traversing it, confirms that nothing else needs that access, and narrows `config/` to `0700` themselves; the command never changes modes or grants access to make a legacy layout pass.

After TLS initialization the helper writes the complete CA certificate and encoded endpoint metadata as `0600` staged files, syncs them, sets `0644`, and then publishes:

- absent `public/`: the stage stays `0700` while it is renamed to `public` without replacement, and only the renamed directory becomes `0755`, so killed or conflicting runs leave only private residue;
- existing safe `public/` (`0700`, `0711`, `0750`, or `0755`): `ca.crt` then `endpoint.json` are renamed in, the empty stage is removed by identity, and `public/` becomes `0755`.

The support root becomes `0711`.
Hardlinked existing files are accepted because publication replaces names and never writes through an existing inode.

If the controller environment update then fails, the helper restores the previous endpoint through a fresh staged inode, or removes the new endpoint when none existed, only while the name still refers to the inode it installed.
Cleanup removes only identity-matched entries it created, retains foreign entries, never recurses, and reports what it retained.

Errors are classified by what is already public:

- a failure before any public rename, including a reply the helper cannot write, removes the owned stage and reports a plain error;
- a failure after the directory or a file has been renamed in, such as a failed mode change, is reported with `public_state=visible` and an operator message that the public directory may hold a partial publication;
- a timed-out or lost helper reply during publication or rollback is reported as an unknown publication state naming the public directory to inspect, because closing the Port does not stop a helper that is mid-rename.

The helper is an explicit host artifact: the macOS builder and payload stage it beside the retained Darwin helpers, a Linux builder stages it for source tests, portable Mix compilation builds nothing native, and an absent helper fails closed.

## Consequences

- Invalid public paths no longer cause TLS side effects.
- Paths the command used to repair silently, such as group-writable, ACL-bearing, or setgid directories, now refuse and must be corrected by the operator.
- A `config/` directory wider than `0700`, or a symlinked or group-writable `controller.env` or TLS source, now refuses before TLS initialization.
- TLS generation invoked by Transport never creates a temporary directory inside `config/tls/`.
- Readers may observe the new CA certificate before the new endpoint metadata, and a rollback restores only the endpoint metadata; the two files are not an atomic transaction.
- A killed helper can leave a private `0700` stage under the support root; it is safe residue and is ignored by later runs.
- Hosts with the legacy `0750 root:admin` `config/` layout refuse until an operator narrows `config/` to `0700` after an ownership review.
- A publisher that cannot take the support-root lock within 90 seconds refuses with `lock_timeout` rather than waiting unattended.
- No crash-durability guarantee is claimed.
- Linux contributors need a host C compiler for source tests.
- Filesystems outside the qualified profiles, including NFS, SMB, FUSE, overlay, XFS, and btrfs, are not supported for the support root.

## SPEC.md impact

Update required in §10.7: adds the local-CA public artifact publication paragraph.
