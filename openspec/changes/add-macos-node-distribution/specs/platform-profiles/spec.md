## ADDED Requirements

### Requirement: Dedicated macOS Node Distribution Is A Separate Profile

Orchard SHALL reserve `dedicated_apple_silicon_macos_node` as the proposed identifier for a clean-host prebuilt Node distribution after owner acceptance.
The profile SHALL compose the existing Apple Silicon macOS platform profile and macOS MLX Node runtime profile with the dedicated Node distribution lifecycle and release evidence.
It SHALL remain distinct from the all-in-one macOS native distribution profile and the experimental `managed_apple_silicon_macos_node` source-baseline transition profile.
It SHALL NOT import Controller roles, source-baseline admission, transition generations, managed handover, automatic update, or managed rollback.
Acceptance of the profile SHALL NOT establish support before the exact Stage A, Stage B, Stage C, release, publication, and support gates pass.

#### Scenario: Dedicated profile is selected

- **WHEN** an operator selects the dedicated clean-host Node profile
- **THEN** Orchard requires the dedicated app, closed Node payload, fixed lifecycle, release activation, enrollment, admission, Peer Grant, Runtime Endpoint, and qualification contracts
- **AND** it does not change the all-in-one profile

#### Scenario: Managed transition is requested

- **WHEN** an operator requests source-baseline adoption or managed generation activation
- **THEN** the dedicated clean-host profile does not claim that operation
- **AND** the separate managed profile and its unmet prerequisites remain authoritative
