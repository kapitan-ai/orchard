## ADDED Requirements

### Requirement: Experimental Linux Node Candidate Remains Separate

Orchard SHALL reserve `ubuntu_24_04_x86_64_node` as an experimental Linux Node platform profile candidate under the `linux-node-platform` contract.
The candidate SHALL have no distribution profile while its proposed target installation path is source development.
It SHALL remain separate from the Linux Controller profile and from every CUDA, ROCm, vLLM, model, and runtime-provider qualification.
The candidate SHALL NOT become a supported platform profile until its applicable acceptance evidence and gates pass, and it SHALL NOT change the support status of any other profile.
The candidate SHALL NOT change Linux Controller profile scope or its Milestone 8 acceptance gates.
This requirement changes `SPEC.md` §§1.4, 4.1, and Milestone 9.

#### Scenario: Linux Node candidate tests pass

- **WHEN** candidate source-development and portable Agent tests pass on a matrix host
- **THEN** Orchard records implementation evidence for the candidate
- **AND** it does not claim Linux Node, distribution, or runtime-provider support

#### Scenario: Linux Controller runs without a local Node

- **WHEN** the Linux Controller profile runs without an admitted local Node Agent
- **THEN** it remains a Controller Host only
- **AND** the Linux Node candidate does not make that host schedulable
