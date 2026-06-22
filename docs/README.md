# Orchard Docs

## Purpose

This directory contains subordinate implementation guidance, process docs, and
durable decision records for Orchard.

Use these docs to support execution, planning, and decision-making during implementation.
Do not treat anything here as a replacement for `SPEC.md`, which remains the
top-level normative product/system contract.

## Source of truth

- `../SPEC.md` — normative product/system contract
- `../README.md` — high-level project overview
- `../CONTRIBUTING.md` — human collaborator workflow
- `../AGENTS.md` — contributor and agent workflow
- `glossary.md` — shared Orchard product language
- `tooling.md` — required local toolchain and agent accelerator guidance
- `local-dev.md` — source development setup and smoke-test guidance
- `process.md` — artifact lifecycle and review gates

## What belongs here

- active milestone plans
- implementation notes that reference the spec
- local tooling and validation guidance
- design decisions not already fixed by the spec
- real runbooks once code and packaging exist

## What does not belong here

- duplicated API contracts from `SPEC.md`
- duplicated schema/state-machine definitions from `SPEC.md`
- contributor workflow rules already covered in `AGENTS.md`
- private or historical coordination workspace notes
- raw prompt exports
- active local goal packages
- unsanitized local evidence
- tool session identifiers
- placeholder docs with no active use

## Writing rules

- reference relevant `SPEC.md` sections
- summarize; do not restate large normative sections
- prefer practical execution guidance over prose
- update or delete stale docs quickly

## Current structure

- `milestones/` — milestone execution plans and active milestone status
- `tooling.md` — mise, validation command, and local tool guidance
- `local-dev.md` — source development setup and smoke-test guidance
- `process.md` — artifact lifecycle and review gates
- `decisions/` — ADR-style records for durable implementation decisions
