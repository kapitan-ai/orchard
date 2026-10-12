## Context

`orchardctl transport enable-local-https` runs as root on the controller host.
It initializes generated local-CA TLS material under the root-only support-root `config/tls` directory, then publishes two non-secret artifacts into `<support-root>/public/`: `ca.crt` and `endpoint.json`.
The support root is `0711` and `public/` is `0755` after publication so non-root status and enrollment readers can read the artifacts by exact path.
ADR 0014 already defines a protected publication model for one-time plaintext credentials; this change applies the applicable parts of that model to public, non-secret artifacts.

## Goals / Non-Goals

**Goals:**

- No interval in which another local UID can traverse, create entries in, or hold writable descriptors on a staging directory or a staged file.
- No TLS side effect when the public path is unsafe.
- No rollback or cleanup that overwrites, removes, or recursively deletes an entry the command did not create.
- Cooperative publishers cannot roll back or delete each other's publication.

**Non-Goals:**

- Root, the effective UID, and privileged writers of ancestors or mounts are outside the threat model.
- No atomic multi-file transaction across `ca.crt` and `endpoint.json`.
- No crash-durability claim.
- No change to TLS material generation, transport modes, certificate provenance, `/ca.crt` serving, or Runtime Endpoints.

## Decisions

### Host-native helper over a Port

A host-native helper, `orchard-transport-publish`, performs every filesystem step through descriptors: component-wise ancestry traversal, filesystem and ACL qualification, `mkdirat` with an explicit `0700` mode, staged writes, `fchmod`, no-replace directory rename, per-file rename, identity-checked unlink, and lock ownership.
Erlang file APIs cannot express descriptor-relative creation, no-follow component traversal, ACL inspection by descriptor, or Darwin mount ownership flags, and shelling out to `getfacl` or `ls -le` cannot bind results to a descriptor.

The CLI opens the helper with `{:packet, 4}` framing and holds it for the whole command.
Requests are `PREPARE <support-root>`, `PUBLISH` with length-prefixed CA and endpoint bytes, `ROLLBACK`, and `COMMIT`.
Responses are `OK ...` or `ERR <code> <errno> [detail]`; codes are stable and mapped to operator messages by the CLI.
End of input before `PUBLISH` removes only the helper's own stage; end of input after `PUBLISH` leaves the publication in place.

The helper source lives under `packaging/native_helpers` because it is shared by Darwin and Linux.
The macOS host-artifact builder compiles it with the retained Darwin helpers, and payload assembly stages it.
A Linux builder compiles it for Linux source tests.
Portable Mix compilation builds no native artifact, and a missing helper fails closed.
A test-only build adds fault injection and pause points and is never staged into payloads.

### Trusted ancestry

The helper opens `/` and each support-root component with `openat(O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)`.
Every component must be owned by root or the effective UID, must not be group- or other-writable unless it is root-owned with the sticky bit, and must carry no extended or default ACL.
A root-owned sticky ancestor is accepted because its sticky bit prevents other UIDs from renaming or removing entries they do not own, and the next component must itself be root- or caller-owned.
On Darwin every component must be on a mount that honors ownership.
Empty components, `.`, `..`, relative paths, and symlinks refuse.
The support root must already exist; the command never creates it.

### Private configuration custody

TLS generation and the controller environment update stay pathname-based and keep their intermediate `chmod` steps.
Their safety rests on the protected ancestor: before TLS initialization the helper requires an existing `config/` to be caller-owned with no group or other access, and an existing `controller.env`, `tls/`, and TLS source files to be non-symlink, caller-owned, not group- or other-writable, ACL-free, and on the support-root device.
With the ancestry validated and `config/` owner-only, no other UID can traverse into or rename within it during those intervals; an earlier descriptor on `config/` cannot look up entries once it is owner-only.
That does not hold for `config/tls/`, which TLS keeps at `0750`: a group member that opened it under a legacy layout keeps lookup and create access through that descriptor after `config/` is narrowed.
Transport therefore calls TLS generation through an internal entry point that creates its temporary directory inside the private stage, which is owner-only from birth and on the same device, and renames finished files into `tls/` with keys already `0600`.
Standalone `orchardctl tls init` is unchanged.
The helper holds the `config/` descriptor and rechecks its identity before publication.

The legacy macOS installer creates `config/` and `config/tls/` as `0750 root:admin`.
That layout refuses unchanged: admin-group traverse would expose the TLS writers' temporary-mode windows to administrator accounts.
The paused installer is not changed; the operator reviews ownership and group reliance on `config/` and narrows it to `0700` before running the command, and the command never repairs modes or grants access.
Unsafe configuration refuses unchanged; it is not repaired.

### Strict parent policy

The support root, `public/`, and the stage must be owned by the effective UID, have no group or other write bit, have no setgid bit, carry no extended or default ACL, share one device, and be on a qualified filesystem:

- Darwin: `fstatfs` reports `MNT_LOCAL`, neither `MNT_IGNORE_OWNERSHIP` nor `MNT_UNION`, type `apfs` or `hfs`, and `fpathconf(_PC_EXTENDED_SECURITY_NP)` is `1`; ACL presence comes from `fstatx_np` and `filesec_query_property(FILESEC_ACL)`, where present, empty, and failed inspection are distinguished and only absence is accepted.
- Linux: `fstatfs` reports the ext4-family magic; `system.posix_acl_access` and `system.posix_acl_default` must both return `ENODATA`, and any other inspection result refuses.
  The test-only helper additionally accepts tmpfs for isolated test trees.

Benign extended ACLs refuse under this bounded policy rather than being parsed or stripped.

### Staging and publication

`PREPARE` takes an exclusive `flock` on the support-root descriptor, polling non-blockingly for at most 90 seconds and exiting without a stage if its client disconnects while waiting, validates existing `public/`, `ca.crt`, and `endpoint.json`, snapshots a safe existing endpoint through a bound descriptor, and creates `.orchard-public-stage-<random>` with `mkdirat(support_fd, leaf, 0700)`.
The post-create check confirms mode `0700`, ownership, device and inode against a no-follow lookup, ACL absence, and the filesystem predicate; it is confirmation, not the safety argument.
A failed post-check retains the entry and reports its identity.

Existing safe `public/` modes `0700`, `0711`, `0750`, and `0755` are accepted; existing `ca.crt` and `endpoint.json` must be regular, caller-owned, not group- or other-writable, and ACL-free.
Hardlink count is not checked because a non-root user may hardlink a root-owned `0644` file, and refusing that would let any local user block publication.

`PUBLISH` creates each staged file with `O_CREAT | O_EXCL | O_NOFOLLOW` and mode `0600`, writes and syncs it, then sets `0644`.
When `public/` is absent, the stage stays `0700` while it is renamed to `public` without replacement; only after the rename is `public/` set to `0755`.
When `public/` exists, `ca.crt` is renamed in first and `endpoint.json` second, the empty stage is removed by identity, and `public/` is set to `0755`.
In both cases the support root is then set to `0711`.

### Failure classification

A failure before any public rename, including a reply the helper cannot write, removes the owned stage and reports a plain error.
A failure after a public rename, such as a failed mode change, adds `public_state=visible`, and the CLI tells the operator the public directory may hold a partial publication.
Closing the Port does not stop a helper that is mid-rename, so a timed-out or lost reply during `PUBLISH` or `ROLLBACK` is reported as an unknown publication state naming the public directory to inspect.

### Rollback and cleanup

`ROLLBACK` restores the snapshotted endpoint into a fresh staged inode with its recorded mode, or removes the endpoint when none existed, only while `public/endpoint.json` is still the inode this publication installed.
A foreign substitution is retained and reported.
The CA certificate is not rolled back: readers may observe the new CA before the new endpoint, or the new CA with the restored endpoint.
Cleanup removes only entries whose identity matches what the helper created and never recurses.
A killed helper may leave a private `0700` stage; it is safe residue and a later run ignores it.

## Risks / Trade-offs

- Paths that were previously repaired now refuse, including group-writable or ACL-bearing public directories. Operators must correct them explicitly.
- Linux production qualification is limited to the ext4-family model; other filesystems refuse rather than being assumed ACL-free.
- The Darwin path cannot be compiled on Linux contributor hosts and depends on the macOS CI lane.
- `flock` serializes only cooperative publishers that use the helper; other same-UID or root writers remain outside the threat model.
