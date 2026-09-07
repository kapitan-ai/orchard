# Source-only Apache-2.0 publication

## Why

Orchard is preparing its initial source-only publication under Apache License 2.0 with AI Singapore as copyright holder.
The repository must state the license grant explicitly while preserving its experimental status and separate binary release gates.

## What Changes

- Add the root Apache-2.0 license and preserve attribution for tracked third-party material.
- Reconcile `SPEC.md` §11, README, contribution guidance, and security status for source-only publication.
- Record AI Singapore copyright attribution, Kapitan-AI hosting, and Najib's continuing project authority in a short decision.
- Keep security/access configuration and the final visibility action subject to separate owner approval.

## Capabilities

### Modified Capabilities

- `packaging-deployment`: explicitly license the initial source-only publication while retaining all public binary release gates.

## Impact

The accepted `packaging-deployment` requirement states that the initial publication is source-only under an explicit Apache-2.0 grant for covered Orchard-authored software and technical documentation, with Copyright 2026 AI Singapore and retained third-party terms and notices.
Source visibility alone grants no rights beyond the applicable license terms.
No official binary, supported release line, SLA, or maintenance commitment is introduced.
The existing macOS build, verification, signing, notarization, stapling, and publication gates remain unchanged.
There are no runtime, API, or packaging implementation changes.
