# goals/

`goals/` is for optional local execution scaffolding produced by agent or
review tools. Active goal packages are transient. They are not durable product
truth.

Tracked on `main`:

- `goals/README.md`
- `goals/_template/**`

Ignored by default:

- `goals/<slug>/goal.md`
- `goals/<slug>/facts.md`
- `goals/<slug>/plan.md`
- `goals/<slug>/evidence.md`
- raw interview JSON
- review/result JSON
- metadata JSON
- local paths
- tool session identifiers
- agent logs

If a goal contains durable product knowledge, promote the conclusion into one
of these standalone Orchard artifacts instead of committing the goal package:

- `SPEC.md`
- `docs/process.md`
- `docs/decisions/**`
- `openspec/README.md` or future verified OpenSpec change files
- product docs
- tests
- code

Do not use a committed goal package as a source of truth for implemented
behavior.
