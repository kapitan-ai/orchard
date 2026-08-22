# Tasks: bound effective request deadlines

## Configuration and admission

- [x] Add the deployment ceiling accessor and environment defaults.
- [x] Validate routing-policy effective deadlines by residency preference.
- [x] Fail closed for incoherent generation timeout configuration.
- [x] Cap stale request deadlines with warning observability.

## Deployment contract

- [x] Document deadline precedence and provisional ceiling.
- [x] Document proxy timeout settings for nginx, Caddy, and Traefik.
- [x] Record the deferred SSE heartbeat decision.

## Regression coverage

- [x] Cover over-ceiling rejection, exact-ceiling acceptance, and under-ceiling behavior.
- [x] Cover residency-specific effective deadline calculation.
- [x] Cover request-time capping and warning output.
- [x] Cover incoherent configuration.
