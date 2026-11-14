## Boundary

SPEC.md §3.5 treats templates as untrusted executable input. The current
request-time and preflight boundary combines a separate process, an explicit
environment, a fresh empty owner-only working directory, the existing deadline
and output cap, and the Jinja sandbox as defence in depth. It is not OS containment.

Use the existing private request transport's lifetime to own an empty `work`
subdirectory; keep request bytes outside that working directory. Attempt cleanup
through the transport's existing `after` clause, including timeout/output failure.
Closing the Port does not guarantee process termination; a still-running helper
can recreate files, so cleanup is not an adversarial containment guarantee.
Share this launch and collection in `Orchard.Tokenizer.HelperProcess.run` between
Client and SafeTokenizationPreflight. Start `/usr/bin/env -i` before the shell/helper
so new ambient environment entries cannot leak through an enumeration race. Also
remove inherited entries through the Port environment option, protecting the
launcher's own loader from ambient runtime overrides.
These layers back each other up and are tested together, not independently:
`env -i` covers the enumeration race, while the Port clear protects the env binary's loader.

The explicit environment contains a constructed PATH (`/usr/bin:/bin` before the
resolved uv executable directory), HOME pointing at the empty working directory,
UV_NO_MANAGED_PYTHON=1, and UV_PYTHON pointing at the resolved source-development
interpreter when available. A UV_PYTHON major/minor prefix, optionally after
`cpython@`, selects the versioned `python<major>.<minor>` executable instead of a
potentially different generic `python3`; no ambient interpreter path is forwarded.
Without a version selector, resolve `python3`. The direct virtualenv entrypoint
needs no Python environment variables. uv needs tool discovery and interpreter selection without
the Controller's home/configuration or a managed Python download. Only the
Controller-derived sentinel-preflight flag is added for segmented requests.
No ambient values are forwarded. Shell-maintained PWD/SHLVL/_ are not inherited
credentials. The wrapper uses uv's project option rather than changing directory.

## Other launch sites

- `Orchard.Models.SafeTokenizationPreflight` launches the helper for eager import
  compatibility and tool-capability definition/history renders. BundleBuilder,
  Importer and ManifestParser's bundle validation reach it. ManifestParser also
  reaches it through `ModelRenderAssets.load/1` during request preparation and
  through `ResidentMemoryBackfill` manifest reparsing. All these renders use the
  same hardened launch as Client; import validation is not a safety review.
- `Orchard.Models.BundleBuilder` separately launches catalog extraction. That
  command parses template syntax/constants but does not render a template.
- The stock MLX Worker consumes prepared prompts/token IDs, not templates.
  The retired TensorFold experiment needs no exception.
- Direct CLI/native tests and the developer calibration and staged-helper smoke
  harnesses (`scripts/kap112_smoke_runner.py` and
  `scripts/verify-staged-venv-closure.sh`) also render outside the Controller
  request-time launch. They are not brought into this boundary by this change.

## Alternatives and limitations

Filtering known secret names is insufficient: secret names are unbounded and
Python, loader, proxy and uv overrides also change execution. Clearing only an
enumerated environment is insufficient against concurrent environment additions.
Relying on the wrapper's package directory as cwd exposes source/config files.

The helper still runs as the Controller's OS user and can access that user's
filesystem and network if the language sandbox is bypassed. OS network/write
denial is planned separately, not a SHALL delivered here. Full read-only
filesystem, child-process prohibition and broader fail-closed limits are deferred.

## Validation

Fail-before/pass-after launch probes exercise the public Client path and
ModelRenderAssets request preparation with Controller sentinel secrets and runtime
overrides, and verify an allow-listed environment, private empty cwd and ordinary
cleanup, including timeout/output failures. Run them on Linux and Darwin; exercise
direct-venv and uv fallback wrappers, existing tokenizer/template tests and pinned
real-template smoke. Run the full applicable Elixir and native workflows and strict
OpenSpec validation. Passing these checks is not a model safety review or OS sandbox proof.
