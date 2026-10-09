# Worker Runtime internal transport

`v1/worker_runtime.proto` is the canonical Worker Runtime schema. Regenerate
its Python and Elixir bindings, shared cluster bindings, descriptor and
preparation fixture with `mise exec -- mix proto.gen.worker`; verify with
`mise exec -- mix proto.check.worker`.

The default-off TensorFold source experiment uses two additive byte fields:

- `WorkerStatusResponse.tensorfold_profile_admission_json` (11) is an identity
  offer, at most 4096 bytes, issued by the explicitly configured bridge on its
  Node-owned socket. Its schema-1 payload binds the profile, model and version,
  artifact, template, configuration, effort, output contract and loaded
  incarnation. The explicitly configured Node preparation gate reads that
  offer on the owned loaded Worker channel and binds the trusted Controller
  history projection before Accepted; the bridge independently validates it
  before admitting generation.
- `ExecuteInferenceRequest.tensorfold_history_projection_json` (15) carries
  that versioned, identity-bound history. Empty retains the baseline contract.
  It is outside negotiated `FrozenExecutionInput`; combining it with
  `preparation_redemption` is rejected because that preparation does not bind
  this field.

These fields do not turn generic observe-only `WorkerCapabilities` into
admission authority. The offer is not forwarded to heartbeats, public model
discovery or shared scheduling, and it grants no readiness or support claim.
An older Worker may ignore unknown protobuf fields; explicit selection of the
bridge executable and its matching contract is required. Neither field
activates the experiment by default or changes the existing MLX foundation.
