# Interpreter selection and evidence boundary

mise owns the exact Python 3.14.10 interpreter; uv continues to own package
environments and must not download or select a second interpreter. CI consumes
the same mise contract on Linux and macos-15. Locked sync must remain strict.
Existing dependency versions should be retained when the universal locks
already cover Python 3.14; changing the interpreter does not justify an
unrelated dependency refresh or a wider runtime support claim.

The active packages and proto tooling require Python `>=3.14`. Ruff's `py314`
target formats exception tuples using Python 3.14 syntax and modernizes type
aliases. Raising the package floor keeps metadata consistent with emitted
source. Relocking removes obsolete interpreter wheels and conditional backports
without upgrading the retained dependencies.

Validation separates model-free suites, pinned tokenizer byte/token/marker
parity, real MLX import/cache/prefill tests, and real model lifecycle evidence.
Missing model assets or hardware must be reported, not counted as passing
qualification. No existing qualification record is changed or approved.
