## ADDED Requirements

### Requirement: Request-time template process boundary

Under SPEC.md §3.5, chat templates SHALL be treated as untrusted executable input.
The request-time Controller renderer SHALL execute out of process with a minimal
explicit environment, no inherited credentials and an initially empty private
working directory. The Jinja sandbox MUST NOT be the only boundary.

#### Scenario: Controller environment contains credentials
- **WHEN** the Controller renders with a secret or Python/uv override in its environment
- **THEN** the request-time helper cannot observe that inherited variable
- **AND** Controller-derived rendering flags still reach the helper

#### Scenario: Renderer launch and cleanup
- **WHEN** the request-time helper starts
- **THEN** its cwd is an empty owner-only directory rather than the Controller cwd
- **AND** that directory is cleaned up after collection, including timeout/output failure
- **AND** the existing timeout and cumulative stdout cap remain in force

### Requirement: Validation is not a safety review

Under SPEC.md §§3.5 and 6.4, import validation and qualification SHALL NOT be
represented as a template safety review. OS sandbox network/write denial is
planned follow-up work, not a guarantee of this change.

#### Scenario: Validated or qualified bundle
- **WHEN** a bundle passes import validation or qualification
- **THEN** its template remains untrusted executable input
- **AND** this evidence does not establish OS containment or template safety
