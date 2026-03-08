# Orchard Docs

## Purpose

This directory contains non-normative implementation guidance for Orchard.

Use these docs to support execution, planning, and decision-making during implementation.
Do not treat anything here as a replacement for `SPEC.md`.

## Source of truth

- `../SPEC.md` — normative product/system contract
- `../README.md` — high-level project overview
- `../AGENTS.md` — contributor and agent workflow

## What belongs here

- active milestone plans
- implementation notes that reference the spec
- design decisions not already fixed by the spec
- real runbooks once code and packaging exist

## What does not belong here

- duplicated API contracts from `SPEC.md`
- duplicated schema/state-machine definitions from `SPEC.md`
- contributor workflow rules already covered in `AGENTS.md`
- placeholder docs with no active use

## Writing rules

- reference relevant `SPEC.md` sections
- summarize; do not restate large normative sections
- prefer practical execution guidance over prose
- update or delete stale docs quickly

## Current structure

- `milestones/` — milestone execution plans and active milestone status
- `decisions/` — ADR-style records for real implementation choices (create only when needed)
