# Domain Docs

How the engineering skills should consume this repo's domain documentation when exploring the codebase.

## Before exploring, read these

- **`CONTEXT-MAP.md`** at the repo root — it points at one `CONTEXT.md` per context. Read each one relevant to the topic.
- **`docs/glossary/CONTEXT.md`** — shared Orchard product language (the context currently listed in `CONTEXT-MAP.md`).
- **`docs/decisions/`** — read decision records that touch the area you're about to work in.

If any of these files don't exist, **proceed silently**. Don't flag their absence; don't suggest creating them upfront. The `/domain-modeling` skill (reached via `/grill-with-docs` and `/improve-codebase-architecture`) creates them lazily when terms or decisions actually get resolved.

## File structure

Orchard uses a root context map and a shared glossary, with ADR-style decisions under `docs/decisions/`:

```
/
├── CONTEXT-MAP.md
├── docs/
│   ├── glossary/
│   │   └── CONTEXT.md                 ← shared product glossary
│   └── decisions/                     ← durable decisions (ADRs)
│       ├── 0001-....md
│       └── ...
└── apps/                              ← Elixir umbrella apps
```

`SPEC.md` remains the normative build contract for behavior, interfaces, states, and milestones. The glossary names concepts; decision records explain durable choices.

## Use the glossary's vocabulary

When your output names a domain concept (in an issue title, a refactor proposal, a hypothesis, a test name), use the term as defined in `docs/glossary/CONTEXT.md`. Don't drift to synonyms the glossary explicitly avoids.

If the concept you need isn't in the glossary yet, that's a signal — either you're inventing language the project doesn't use (reconsider) or there's a real gap (note it for `/domain-modeling`).

## Flag decision conflicts

If your output contradicts an existing decision record under `docs/decisions/`, surface it explicitly rather than silently overriding:

> _Contradicts ADR-0007 (event-sourced orders) — but worth reopening because…_
