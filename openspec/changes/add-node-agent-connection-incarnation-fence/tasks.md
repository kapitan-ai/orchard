## 1. Acceptance gate

- [x] 1.1 Retain deterministic evidence that unchanged-authority reconnect has identical native BEAM and credential/grant identity at the commit fence.
- [x] 1.2 Obtain Repository Owner acceptance for the narrow ephemeral authenticated-connection incarnation amendment; boot-only incarnation was reviewed and rejected as insufficient.

## 2. Implementation after acceptance

- [x] 2.1 Generate a random in-memory incarnation per authenticated connection without persistence.
- [x] 2.2 Carry it only in authenticated status observations and validate its closed shape.
- [x] 2.3 Fence durable observation commit against connection replacement and current exact authority.
- [x] 2.4 Clear live incarnation evidence on disconnect, authority loss, and Controller restart.
- [x] 2.5 Prove post-response/pre-commit replacement, unchanged-authority reconnect, Node restart, Controller restart, and N/N-1 refusal.
- [x] 2.6 Run focused, full, coverage, strict OpenSpec, and portable gates.
