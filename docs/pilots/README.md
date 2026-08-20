# Pilot runbook

This page supports the slim internal source-dev API pilot tracked on issue #118
(Revision 6).

The first pilot is intentionally light:

- we install source-dev Orchard on a couple of hosts
- we choose and load models ourselves
- clients call `/v1/chat/completions` and/or `/v1/responses`
- we observe real usage for about two weeks and collect feedback

It is not a packaged-readiness program and not a full M5 observability gate.

## Start bar

Before opening the window:

1. Controller and at least one healthy worker are up.
2. End-to-end inference works from outside the box on the APIs offered to clients.
3. One tenant exists, with per-user API clients/tokens where practical.
4. At least one operator-chosen model is loaded on a schedulable node and
   granted to the pilot tenant with `orchardctl models access grant`; model
   access is deny-by-default and nothing is granted automatically.
5. Operators can inspect requests, restart a node, and revoke a token.
6. Clients have a short note covering allowed content, support hours, contact path, and stop authority.

## Operator note (site-local)

Keep a private note with:

- host roles and install pointers
- loaded model id(s) and node(s)
- tenant id and token mint/revoke steps
- API base URL(s) given to clients
- capture-mode statement (prefer `metadata`)
- optional synthetic-check command, if any

Do not commit credentials, tokens, private host paths, raw results, or response
content.

## Optional synthetic check

A recurring authenticated check is useful so overnight total outage is obvious.
It is optional for pilot start.

If you use the Phase 0 producer from issue #115:

- producer, schemas, and launcher live with #115
- example pin format: `issue-118-cp1-observability-probe-pin.example.json`
- configuration and results stay site-local
- failed check results are still data; silence means no qualifying result arrived

Issue #182 tracks richer silence-detection hardening. It is deferred and is not
a #118 start gate.

### Optional pin fields

When you do pin a check configuration, record:

- `artifact_git_sha`: commit that contains the exact producer script
- `config_sha256`: SHA-256 of the exact non-secret configuration bytes
- `config_path`: consumer-owned configuration location
- `result_schema_version` and `terminal_validation`

Create the digest without resolving environment variables named by the
configuration:

```sh
shasum -a 256 path/to/your-non-secret-probe-config.json
```

## During the window

Record:

- client friction and workarounds
- API compatibility surprises (error shapes, streaming, cancel, tools)
- unplanned operator interventions
- defects to file or extend after the window

## Related issues

| Issue | Role under Revision 6 |
| --- | --- |
| #118 | Pilot tracker |
| #115 | Optional probe producer |
| #182 | Deferred optional silence-detection hardening |
| #126 | Console readiness bug; not a client-path start gate |
| #127 | Post-pilot packaged Model Hub journey |
| #128 | Scheduler/admission reasons; fix when it hurts |
