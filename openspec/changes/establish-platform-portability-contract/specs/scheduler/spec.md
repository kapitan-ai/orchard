## ADDED Requirements

### Requirement: Normalized Runtime And Device Eligibility
Production scheduling SHALL match model artifact requirements to fresh authenticated runtime-provider capabilities, acceleration capabilities, device resources, memory domains, and Controller policy.
Scheduling MUST NOT authorize work solely from operating-system names, `worker_backend` strings, transport type, or inferred provider defaults.
Missing, malformed, stale, conflicting, or version-incompatible required capability evidence SHALL fail closed with stable provider-neutral explanation reasons.
This requirement refines `SPEC.md` §§5.5, 5.7, 5.9, and 7.3.5.

#### Scenario: Artifact supports MLX and future CUDA providers
- **WHEN** an artifact declares compatibility with multiple runtime-provider requirement sets
- **THEN** the scheduler evaluates each candidate against its normalized provider and device evidence
- **AND** it does not rewrite artifact format as `mlx` or `cuda`

#### Scenario: Provider string exists without capabilities
- **WHEN** an observation contains a provider identifier but omits required format, feature, device, or memory capability evidence
- **THEN** the scheduler rejects that capability match
- **AND** it does not infer eligibility from the provider identifier

### Requirement: Memory Eligibility Uses Memory Domains
Scheduler memory eligibility and ranking SHALL use normalized resource identities and memory domains such as unified, device, and system memory with fresh capacity and headroom evidence.
Provider-specific working-set or VRAM fields MAY feed adapter normalization but MUST NOT be required by portable scheduling.

#### Scenario: Unified-memory and discrete-GPU candidates are compared
- **WHEN** compatible candidates report normalized unified-memory and device-memory resources
- **THEN** each candidate is evaluated against the model requirement applicable to its memory domain
- **AND** portable scheduling does not assume that all accelerators share Apple unified-memory semantics
