# Pilot artifact pins

Pilot acceptance evidence must identify the exact producer artifact and the
exact non-secret configuration used to collect it. Pins are consumer-owned:
they are not probe results and must never contain credentials or credential
values.

## Issue #115 producer and issue #118 consumer

Issue #115 owns the versioned Phase 0 probe implementation, its configuration
and result schemas, and the example pin at
`issue-118-cp1-observability-probe-pin.example.json`. Issue #118 owns the CP1
copy of the probe configuration, the actual pin, the invocation cadence, and
the retained pilot results.

The #118 pin records:

- `artifact_git_sha`: the 40-character Git commit SHA containing the exact
  `scripts/support/observability_probe.exs` artifact used by the pilot;
- `config_sha256`: the lowercase SHA-256 digest of the exact non-secret JSON
  configuration bytes used for the run;
- `config_path`: the consumer-owned configuration location;
- `result_schema_version` and `terminal_validation`: the interpretation
  contract for collected results.

Create the digest without resolving either environment variable named by the
configuration:

```sh
shasum -a 256 pilot-owned/issue-118-cp1-observability-probe.json
```

## Issue #118 recurring HTTP-only consumer

The CP1 remote consumer runs the pinned probe over HTTPS every five minutes
with configuration and result schema version 1 and
`terminal_validation: "http_only"`. It retains each stdout result separately
from stderr without overwriting earlier runs and produces an immutable daily
digest for the retained result set.

Probe freshness advances only when the result sink receives one parseable
schema-version-1 result object. Both `pass` and `fail` outcomes prove that the
consumer is still publishing observations. Starting the scheduled process,
creating an output file, or receiving missing or malformed stdout does not
advance freshness.

Transport, HTTP, and invalid-stream failures normally produce a `fail` result,
so they are probe observations rather than probe loss. The no-data alert fires
after 12 minutes without a qualifying result. Prove that alert by interrupting
the consumer or its result-publication path, then restore publication and
record the alert recovery. Breaking the inference endpoint alone is not
probe-loss proof when the consumer retains a failure result.

The actual pin, byte-exact non-secret configuration, scheduler definition,
protected result location, retained results, daily digests, and operational
screenshots are site-local evidence. Record sanitized references and outcomes
on issue #118 or child issue #182; do not commit them, credentials, raw
results, machine-specific paths, hostnames, tenant or user identifiers, or
response content.

This recurring consumer and no-data proof do not satisfy #118's separate
Controller-local reconciliation cadence or its independent readiness-failure
and inference-failure alert proofs.

## Update and rollback

For an update, review the producer change, copy the new configuration if its
schema changed, recompute `config_sha256`, replace `artifact_git_sha`, and run a
fresh probe before accepting the pin. Never move a pin implicitly with a
branch name or tag.

For rollback, restore the last accepted pin and its byte-identical
configuration, check out the recorded `artifact_git_sha`, verify the
configuration digest, and run a fresh probe. Keep the failed update's result as
pilot evidence, but do not copy response content, credentials, tenant IDs,
DSNs, or stack traces into the pin.
