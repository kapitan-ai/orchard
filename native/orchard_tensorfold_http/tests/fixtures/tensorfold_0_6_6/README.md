# TensorFold 0.6.6 CPU-only source fixtures

These four `.py.txt` files are byte-for-byte copies of `src/tensorfold/engine/prefill_plan.py` and `src/tensorfold/server/{errors,messages,text}.py` from [TensorFold commit cb2ebf0540f42604e2759b2ddef497861e928248](https://github.com/ashhart/TensorFold/tree/cb2ebf0540f42604e2759b2ddef497861e928248).
Tests load only these pure modules, without importing the native package, MLX, model families, or weights.
The text extension preserves upstream source bytes against local formatting.
SHA-256 identities are asserted by the test loader.

The retained LICENSE, NOTICE, and MIT.txt are unchanged upstream attribution and licences.
These fixtures exercise the pinned planning and probing algorithms, not native performance or model qualification.
