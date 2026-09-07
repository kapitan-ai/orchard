# ADR 0032: Source-only Apache-2.0 publication

## Status

Accepted.
Date: 2026-09-07.

## Context

Orchard needs a durable boundary for its initial source publication before any official binary release.
The publication must preserve the existing macOS distribution gates and the terms for material that Orchard does not own.

## Decision

Covered Orchard-authored software and technical documentation are published under the Apache License, Version 2.0, with Copyright 2026 AI Singapore.
The repository remains hosted at `kapitan-ai/orchard`.
The publication is source-only and experimental, and source visibility alone grants no rights beyond the applicable license terms.
Third-party software, models, tokenizers, assets, and other separately licensed material are excluded from that grant and remain subject to their own terms and notices.
Orchard logos and distinctive brand assets are excluded, and no trademark rights are granted.
Najib retains final authority over project direction, contribution acceptance, merges, releases, and publication.
No official binary, supported release, SLA, or maintenance commitment is provided by this publication.
Existing tags remain unsupported pre-public development history; this decision does not authorize deleting, rewriting, or promoting them into releases.
Future macOS binaries remain subject to the existing build, verification, signing, notarization, stapling, and publication gates.

## Consequences

The repository has a clear source license and publication boundary without changing runtime behavior or authorizing binary distribution.

## SPEC.md impact

Updates §11 for the initial source-only Apache-2.0 grant and preserves the existing binary release gates.
