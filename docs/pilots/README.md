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
