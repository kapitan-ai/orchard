# ADR 0045: Controller template-renderer process boundary

## Status

Accepted on 2026-11-14 by Najib, product owner. Acceptance covers the delivered
environment and working-directory stage only, not OS containment.

## Context

Chat templates arrive in third-party bundles and execute Python-backed Jinja
operations. Digest binding identifies bytes; it does not prove safety. Import
compatibility and manual qualification under SPEC.md §6.4 and ADR 0028 are not a
safety review. Template code that escapes the language-level sandbox runs as the
Controller's OS user. Removing what the helper inherits narrows its ambient
authority, but does not contain an escaped template.

## Decision

Treat templates as untrusted executable input. Route `Orchard.Tokenizer.Client`
and `Orchard.Models.SafeTokenizationPreflight` through the shared
`Orchard.Tokenizer.HelperProcess.run` launch, removing inherited environment
and cwd authority from request-time and import/preflight renders. Use a fresh
empty mode-0700 `work` directory within the private request transport's lifetime;
request bytes remain outside the cwd. Attempt removal of the transport tree
after collection on success and error, including timeout/output failure.

Clear inherited Port environment entries before starting `/usr/bin/env -i`;
the latter ensures even concurrently added ambient entries do not reach the
shell or renderer. Construct the following allow-list rather than forwarding
Controller environment values:

| Entry | Source and reason |
|---|---|
| `PATH` | `/usr/bin:/bin`, followed only by the resolved uv executable directory when available; system utilities take precedence over executables alongside uv, while the source-development fallback can locate uv. No inherited PATH list. |
| `HOME` | The fresh working directory; uv's default user configuration/cache discovery must not use the Controller's home. |
| `UV_PYTHON` | Absolute resolved versioned Python executable when available. Extract the Controller's `UV_PYTHON` major/minor version, accepting `3.14`, `3.14.10` and `cpython@3.14`, and resolve `python<major>.<minor>`; otherwise resolve `python3`. Never forward an ambient Python path. This preserves the source toolchain's interpreter family when generic `python3` is a different installation. Not needed by the direct virtualenv entrypoint. |
| `UV_NO_MANAGED_PYTHON` | Fixed `1`; keep uv on the installed interpreter rather than selecting/downloading a managed Python. |
| `ORCHARD_TOKENIZER_SKIP_SENTINEL_PREFLIGHT` | Only on segmented requests, `0` or `1` derived by the Controller from compatibility evidence; never the ambient value. |

The shell may generate non-secret PWD, SHLVL and `_` values. Under the cleared
environment, Python 3.14 obtains UTF-8 through C-locale coercion or UTF-8 mode for
the C/POSIX locale (PEP 538/540), not an unconditional UTF-8 default. Neither it
nor the installed virtualenv needs inherited locale, PYTHONPATH, VIRTUAL_ENV,
loader variables, tokens, proxies, cookies, DSNs or secret paths.
The wrapper uses `uv run --project` so its fallback preserves the controlled cwd.
The existing request timeout and cumulative stdout cap remain unchanged.

## Other render sites

`Orchard.Models.SafeTokenizationPreflight` starts another helper for eager
safe-tokenization import checks and tool-capability definition/history renders.
Its callers include BundleBuilder, Importer and ManifestParser's bundle
validation. ManifestParser also reaches it during request preparation through
`ModelRenderAssets.load/1` and during `ResidentMemoryBackfill` manifest reparsing.
All these preflight renders use the shared hardened launch; they are not an
import-only exclusion. Passing their checks does not establish safety.
BundleBuilder also launches catalog extraction, which parses template syntax
and constants without rendering. The stock MLX Worker consumes prepared prompts
or token IDs. TensorFold was retired; no in-process exception is needed.

Developer and packaging proofs also invoke the renderer directly:
`scripts/kap112_smoke_runner.py` uses uv for exact-input calibration, and
`scripts/verify-staged-venv-closure.sh` runs synthetic installed-helper preflight.
Those harnesses, direct package/CLI invocations and native template tests are not
Controller request-time launch paths and remain outside this step.

## Consequences

This limits what the helper inherits; it is not containment. The helper still
runs as the Controller's OS user, so template code that escapes the Jinja sandbox
can still read that user's files and process state, including the Controller's
own environment (for example through `/proc` on Linux), write outside its working
directory, start programs and use the network. HOME/cwd isolation is not
filesystem denial. Absolute installation and asset paths remain necessary
inputs, not a capability boundary. The direct virtualenv is the normal path;
source development must provision the pinned toolchain and dependencies.

Per-launch HOME means a cold uv cache and no user uv configuration; dropping
UV_INDEX_URL, UV_OFFLINE and UV_CACHE_DIR means an unprovisioned air-gapped
fallback fails rather than using those overrides, and the wrapper's original
`${HOME}/.local/bin/uv` candidate is unavailable. Because the work directory and
its HOME are removed on timeout while uv may still be running, an unprovisioned
fallback can fail mid-install and start again on the next request. `TZ` is not
forwarded, so templates that read the current time use the host's default time
zone rather than a Controller override.

Transport cleanup is best effort: closing the Port on timeout or excess output
does not guarantee helper/descendant termination or prevent a still-running
same-user process from recreating files. Tests cover removal for ordinary
success, timeout and stdout-cap helpers, not adversarial process containment.

OS network/write denial is planned follow-up work with separate platform deny-path
qualification, not a binding guarantee delivered by this change. Comprehensive
CPU/memory limits, stronger termination/reaping, OS containment at every render
site (including CLI/dev harnesses), a read-only filesystem, denial of same-user
process inspection and child-process prohibition are not delivered here.
The process and environment boundary is a second layer against inheritance only;
until OS containment is delivered, the Jinja sandbox remains the only barrier
against template code execution. No new
service, VM, model-admission gate or support claim is introduced.

## SPEC.md impact

Add the template-trust policy and the shared rendering/preflight environment and
cwd boundary to §3.5, with a pointer from §6.4. Explicitly distinguish planned OS
containment from current guarantees. This is separate from the narrow global
restrictions in `harden-chat-template-globals`.
