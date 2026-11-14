## ADDED Requirements

### Requirement: Template process boundary

Under SPEC.md §3.5, chat templates SHALL be treated as untrusted executable input.
The Controller's request-time and preflight renderers SHALL execute out of process
with a minimal explicit environment, no inherited environment credentials and an
initially empty private working directory. The Jinja sandbox MUST NOT be the only
boundary.

#### Scenario: Controller environment contains credentials
- **WHEN** the Controller renders or preflights with a secret or Python/uv override in its environment
- **THEN** the helper environment contains only the explicit allow-list and no inherited environment credentials
- **AND** Controller-derived rendering flags still reach the helper

#### Scenario: Renderer launch and cleanup
- **WHEN** the request-time or preflight helper starts
- **THEN** its cwd is an empty owner-only directory rather than the Controller cwd
- **AND** the Controller attempts removal of the private transport tree after collection, including timeout/output failure
- **AND** this best-effort cleanup does not guarantee that a still-running helper or its descendants cannot recreate files
- **AND** the existing timeout and cumulative stdout cap remain in force

### Requirement: Validation is not a safety review

Under SPEC.md §§3.5 and 6.4, import validation and qualification SHALL NOT be
represented as a template safety review. The process/environment boundary limits
what the helper inherits and is not containment: template code that escapes the
Jinja sandbox can still read same-user files and process state, including the
Controller's environment, write outside its working directory, start programs and
use the network; see ADR 0045.

#### Scenario: Validated or qualified bundle
- **WHEN** a bundle passes import validation or qualification
- **THEN** its template remains untrusted executable input
- **AND** this evidence does not establish OS containment or template safety
