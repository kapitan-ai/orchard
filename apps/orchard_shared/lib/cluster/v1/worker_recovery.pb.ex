defmodule Orchard.Cluster.V1.WorkerRecoveryKey do
  @moduledoc false

  use Protobuf,
    full_name: "cluster.v1.WorkerRecoveryKey",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :node_id, 1, type: :string, json_name: "nodeId"
  field :model_id, 2, type: :string, json_name: "modelId"
  field :version, 3, type: :string
end

defmodule Orchard.Cluster.V1.WorkerRecoveryMutation do
  @moduledoc false

  use Protobuf,
    full_name: "cluster.v1.WorkerRecoveryMutation",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :key, 1, type: Orchard.Cluster.V1.WorkerRecoveryKey
  field :expected_epoch, 2, type: :string, json_name: "expectedEpoch"
  field :expected_revision, 3, type: :uint64, json_name: "expectedRevision"
  field :transition_id, 4, type: :string, json_name: "transitionId"
  field :record_json, 5, type: :string, json_name: "recordJson"
end

defmodule Orchard.Cluster.V1.WorkerRecoveryCommand do
  @moduledoc false

  use Protobuf,
    full_name: "cluster.v1.WorkerRecoveryCommand",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :key, 1, type: Orchard.Cluster.V1.WorkerRecoveryKey
  field :expected_epoch, 2, type: :string, json_name: "expectedEpoch"
  field :expected_revision, 3, type: :uint64, json_name: "expectedRevision"
  field :command_id, 4, type: :string, json_name: "commandId"
  field :action, 5, type: :string
  field :reason, 6, type: :string

  field :load_request, 7,
    type: Orchard.Cluster.V1.EnsureModelLoadedRequest,
    json_name: "loadRequest"
end

defmodule Orchard.Cluster.V1.WorkerRecoveryResult do
  @moduledoc false

  use Protobuf,
    full_name: "cluster.v1.WorkerRecoveryResult",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :status, 1, type: :uint32
  field :reason, 2, type: :string
  field :record_json, 3, type: :string, json_name: "recordJson"
end

defmodule Orchard.Cluster.V1.ControllerWorkerRecoveryService.Service do
  @moduledoc false

  use GRPC.Service,
    name: "cluster.v1.ControllerWorkerRecoveryService",
    protoc_gen_elixir_version: "0.16.0"

  rpc :ReadWorkerRecoveryCheckpoint,
      Orchard.Cluster.V1.WorkerRecoveryKey,
      Orchard.Cluster.V1.WorkerRecoveryResult

  rpc :CommitWorkerRecoveryCheckpoint,
      Orchard.Cluster.V1.WorkerRecoveryMutation,
      Orchard.Cluster.V1.WorkerRecoveryResult
end

defmodule Orchard.Cluster.V1.ControllerWorkerRecoveryService.Stub do
  @moduledoc false

  use GRPC.Stub, service: Orchard.Cluster.V1.ControllerWorkerRecoveryService.Service
end

defmodule Orchard.Cluster.V1.NodeWorkerRecoveryService.Service do
  @moduledoc false

  use GRPC.Service,
    name: "cluster.v1.NodeWorkerRecoveryService",
    protoc_gen_elixir_version: "0.16.0"

  rpc :InspectWorkerRecoveryPlacement,
      Orchard.Cluster.V1.WorkerRecoveryKey,
      Orchard.Cluster.V1.WorkerRecoveryResult

  rpc :RecoverWorkerPlacement,
      Orchard.Cluster.V1.WorkerRecoveryCommand,
      Orchard.Cluster.V1.WorkerRecoveryResult
end

defmodule Orchard.Cluster.V1.NodeWorkerRecoveryService.Stub do
  @moduledoc false

  use GRPC.Stub, service: Orchard.Cluster.V1.NodeWorkerRecoveryService.Service
end
