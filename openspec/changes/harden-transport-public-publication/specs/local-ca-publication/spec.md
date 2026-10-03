## ADDED Requirements

### Requirement: Public Path Validation Precedes TLS Generation

`orchardctl transport enable-local-https` SHALL validate the support-root ancestry, support root, existing `public/` directory, and existing public artifacts, and SHALL create its private stage and take publisher serialization, before it initializes or reuses TLS material.
An unsafe path SHALL refuse with nothing changed and no TLS side effect.
This requirement implements the local-CA publication paragraph of `SPEC.md` §10.7.

#### Scenario: unsafe public directory refuses before TLS

- **WHEN** `public/` is group- or other-writable, foreign-owned, a symlink, a regular file, setgid, ACL-bearing, or on an unqualified filesystem
- **THEN** the command exits nonzero with a precise reason
- **AND** TLS initialization is not invoked and the directory is unchanged

#### Scenario: unsafe ancestor refuses

- **WHEN** any support-root ancestor is a symlink, is foreign-owned, is writable by other UIDs without being a root-owned sticky directory, or carries an ACL
- **THEN** the command refuses before creating any entry

### Requirement: Private Configuration Custody Precedes TLS Generation

Before TLS initialization, an existing `config/` directory SHALL be caller-owned with no group or other access, and an existing `config/controller.env`, `config/tls/`, and TLS source files SHALL be non-symlink, caller-owned, not group- or other-writable, and ACL-free.
Unsafe configuration SHALL refuse with nothing changed and SHALL NOT be repaired.

#### Scenario: config directory is group- or other-accessible

- **WHEN** `config/` has mode `0750`, `0755`, or `0777`, or carries an ACL
- **THEN** the command refuses before TLS initialization
- **AND** the directory mode and `controller.env` contents are unchanged

#### Scenario: legacy installer config layout

- **WHEN** `config/` has the legacy installer layout `0750` owned by `root:admin`
- **THEN** the command refuses before TLS initialization without changing modes or granting access
- **AND** the operator must review ownership and narrow `config/` to `0700` before retrying

#### Scenario: controller.env or TLS source is substituted

- **WHEN** `controller.env` or a TLS source file is a symlink, is foreign-owned, or is group-writable
- **THEN** the command refuses before TLS initialization without reading through or modifying the substituted entry

#### Scenario: TLS generation stages inside the private stage

- **WHEN** the command initializes TLS material
- **THEN** TLS generation creates its temporary directory inside the owner-only private stage rather than inside `config/tls/`
- **AND** a directory descriptor another UID opened on `config/tls/` before `config/` was narrowed cannot reach any temporary entry

### Requirement: Private Stage Is Safe From Birth

The publication stage SHALL be created with an explicit `0700` creation mode relative to a validated support-root descriptor, under a random name, without changing the process umask and without later mode repair.
Extended or default ACLs, setgid directories, unqualified filesystems, and ownership-ignoring mounts SHALL refuse before creation, and failed ACL or filesystem inspection SHALL refuse.
A post-create mismatch SHALL retain the entry and report its identity.

#### Scenario: restrictive or permissive caller umask

- **WHEN** the helper runs under umask `0022`, `0077`, `0002`, or `0000`
- **THEN** the stage is born `0700`, published files are `0644`, `public/` is `0755`, and the support root is `0711`
- **AND** the caller's umask is unchanged

#### Scenario: another local UID probes the stage

- **WHEN** another local UID attempts to traverse, create in, open for write, change mode of, or set attributes on the stage before, during, or after creation
- **THEN** every attempt fails
- **AND** after publication that UID can read `public/ca.crt` and `public/endpoint.json`

#### Scenario: absent public directory is published

- **WHEN** `public/` is absent
- **THEN** the stage remains `0700` until it is renamed to `public`
- **AND** only the renamed `public/` becomes `0755`

### Requirement: Publication Is Staged And Identity Bound

The CA certificate and encoded endpoint metadata SHALL be complete inside the stage before any public name changes.
An absent `public/` SHALL be published as a completed directory without replacement; an existing safe `public/` SHALL receive per-file renames with the CA certificate before the endpoint metadata.
The two files SHALL NOT be described as an atomic transaction.
No TLS private key SHALL be written to a public artifact.

#### Scenario: hardlinked existing endpoint

- **WHEN** a safe existing `endpoint.json` has additional hardlinks
- **THEN** publication proceeds and the linked inode is not modified

#### Scenario: rollback after controller environment failure

- **WHEN** the controller environment update fails after publication
- **THEN** the previous endpoint is restored through a fresh inode, or the new endpoint is removed when none existed
- **AND** a substituted foreign entry is retained and reported instead of overwritten or removed

### Requirement: Publishers Serialize And Clean Up Only Their Own Entries

Cooperative publishers SHALL serialize on the support root for the whole command.
Cleanup and rollback SHALL act only on entries whose identity matches what the publisher created, SHALL retain foreign entries and safe residue, and SHALL NOT delete recursively.

#### Scenario: competing publishers

- **WHEN** two publishers target the same support root concurrently
- **THEN** the second waits until the first commits or rolls back
- **AND** neither removes or rolls back the other's publication

#### Scenario: bounded wait

- **WHEN** the first publisher holds the lock past the bounded wait, or the waiting client disconnects
- **THEN** the waiting helper refuses with `lock_timeout` or exits, without creating a stage

### Requirement: Publication Failures Report Public State

A failure before any public name changes SHALL remove the owned stage and report a plain error, including when the helper cannot write its reply.
A failure after a public name has changed SHALL be reported as a visible partial publication.
A timed-out or lost helper reply during publication or rollback SHALL be reported as an unknown publication state that names the public directory to inspect.

#### Scenario: mode change fails after the rename

- **WHEN** widening `public/` fails after it was renamed into place
- **THEN** the error reports that public artifacts are visible and must be inspected

#### Scenario: helper lost during publication

- **WHEN** the helper dies or times out before replying to `PUBLISH`
- **THEN** the CLI reports that the publication state is unknown and names the public directory

### Requirement: Publication Helper Is An Explicit Host Artifact

The publication helper SHALL be compiled only by explicit host-artifact builders and staged into the selected `orchard_cli` application `priv` directory.
Portable Mix compilation SHALL NOT build it, and the command SHALL refuse when the helper is absent, cannot execute, or violates the protocol.
The macOS payload SHALL stage the production helper; the test-only helper SHALL NOT be staged into payloads.

#### Scenario: helper absent

- **WHEN** the publication helper is not staged
- **THEN** the command refuses before TLS initialization with guidance to build the helper
