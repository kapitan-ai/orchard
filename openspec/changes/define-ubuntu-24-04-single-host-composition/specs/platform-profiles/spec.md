## MODIFIED Requirements

### Requirement: Ubuntu Single-Host Profile Is Exact And Non-Implying

Orchard SHALL reserve `ubuntu_24_04_x86_64_single_host` as an accepted,
unimplemented distribution and acceptance profile that composes the exact
existing Ubuntu Server 24.04 LTS x86_64 Node host tuple with one portable
Controller, locally managed PostgreSQL 16, one separately admitted local Node,
and only separately qualified Worker Runtime providers.
It SHALL permit exactly one canonical source-development installation and one
Controller per host; Debian package installation and qualification are not part
of the current profile.
The profile SHALL NOT broaden `ubuntu_24_04_x86_64_node`, qualify Ubuntu 26.04
or generic Linux, or imply any provider, model, Serving Profile, release,
deployment, publication, or support status.
A Controller-bearing host SHALL become schedulable only through its distinct
local Node identity and complete Node eligibility contract.

#### Scenario: Appliance has no admitted local Node

- **WHEN** the Controller and local PostgreSQL cluster are ready but no local Node has completed admission and authenticated observation
- **THEN** the host remains a Controller Host only
- **AND** the scheduler does not infer local capacity

#### Scenario: Ubuntu 26.04 candidate is available

- **WHEN** an experimental Ubuntu 26.04 Node package exists
- **THEN** it remains outside the Ubuntu 24.04 single-host profile
- **AND** its evidence cannot satisfy this profile's qualification
