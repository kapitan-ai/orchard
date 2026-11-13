# Worker Runtime internal transport

`v1/worker_runtime.proto` is the canonical Worker Runtime schema. Regenerate
its Python and Elixir bindings, shared cluster bindings, descriptor and
preparation fixture with `mise exec -- mix proto.gen.worker`; verify with
`mise exec -- mix proto.check.worker`.
