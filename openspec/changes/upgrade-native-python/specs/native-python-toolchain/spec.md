## ADDED Requirements

### Requirement: One pinned native Python interpreter
Native package development and CI SHALL use the Python 3.14.10 interpreter
selected by mise. uv SHALL use that interpreter without managed downloads or
a per-package interpreter fallback. Linux portable, provider conformance and
macOS MLX validation SHALL synchronize their package environments from the
committed locks.

#### Scenario: Active native environment synchronization
- **WHEN** a native package compatible with the selected interpreter is synchronized
- **THEN** uv uses Python 3.14.10 and the committed dependency lock
- **AND** CI validates the same interpreter identity

### Requirement: Interpreter changes preserve qualification boundaries
An interpreter change SHALL trigger affected runtime requalification under
docs/model-qualification.md and SPEC §7.2.9. Passing tests SHALL NOT approve,
modify or transfer an existing qualification record or support claim.

#### Scenario: Python upgrade validation
- **WHEN** Python 3.14.10 passes native suites and bounded runtime checks
- **THEN** those results are implementation evidence for the tested tuple only
- **AND** unavailable or failing lifecycle checks remain explicit limitations
