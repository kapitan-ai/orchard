## ADDED Requirements

### Requirement: Worker reasoning evidence is bound to one loaded artifact

A future Worker Runtime reasoning envelope SHALL be scoped to exactly one `WorkerLoadedBinding` and one `service_incarnation`. Each complete advertised tuple SHALL contain the `SPEC.md` §7.5.3a eleven fields — generation policy, projection, reasoning effort, model artifact digest, chat-template digest, render contract, render contract version, parser family, parser version, runtime contract version, and event-binding version — match that binding's artifact digest, and resolve its selected profile exactly once in the enclosing capability envelope. A present incomplete envelope, duplicate or conflicting tuple, unknown required value, or missing loaded binding SHALL prove no reasoning support rather than legacy omission.

Concrete Worker Runtime schema design remains blocked pending owner approval. This delta selects no protobuf field/tag allocation, enum value, `nil`-presence encoding, RPC or service owner, cross-boundary definition location, evidence/preparation/proof message layout, or execution-redemption shape. Existing references to a loaded binding, a sibling reasoning envelope, or shared reasoning definitions do not authorize protocol source declarations from this contract.

Load replacement, unload, failed destructive unload, or Worker Runtime teardown SHALL invalidate advertised reasoning evidence and any preparation authorization for the affected loaded instance.

#### Scenario: Same worker process reloads an artifact

- **WHEN** the Worker Runtime reloads an artifact without changing `service_incarnation`
- **THEN** prior reasoning evidence and preparation authorization are invalid
- **AND** the Worker must publish fresh evidence for the new loaded binding before negotiated execution

#### Scenario: Terminal failure has known zero output

- **WHEN** a Worker-originated terminal failure proves exact cumulative output usage of zero
- **THEN** the future presence-aware failure usage field is present with zero
- **AND** absence remains distinct missing evidence
